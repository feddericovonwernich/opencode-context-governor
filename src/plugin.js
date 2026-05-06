const DEFAULTS = {
  enabled: true,
  informThreshold: 120_000,
  warnThreshold: 140_000,
  handoffThreshold: 150_000,
  reserveOutputTokens: 12_000,
  estimateCharsPerToken: 3,
  noteMode: "always", // always | warn | handoff
  appendToolWarnings: true,
  mutateUserMessageAtHandoff: true,
  log: false,
  handoffInstruction:
    "Write a handoff letter and stop. Include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps.",
}

function numberOption(value, fallback) {
  return Number.isFinite(value) && value >= 0 ? value : fallback
}

function booleanOption(value, fallback) {
  return typeof value === "boolean" ? value : fallback
}

function stringOption(value, fallback) {
  return typeof value === "string" && value.trim() ? value : fallback
}

function normalizeOptions(options = {}) {
  return {
    enabled: booleanOption(options.enabled, DEFAULTS.enabled),
    informThreshold: numberOption(options.informThreshold, DEFAULTS.informThreshold),
    warnThreshold: numberOption(options.warnThreshold, DEFAULTS.warnThreshold),
    handoffThreshold: numberOption(options.handoffThreshold, DEFAULTS.handoffThreshold),
    reserveOutputTokens: numberOption(options.reserveOutputTokens, DEFAULTS.reserveOutputTokens),
    estimateCharsPerToken: Math.max(1, numberOption(options.estimateCharsPerToken, DEFAULTS.estimateCharsPerToken)),
    noteMode: ["always", "warn", "handoff"].includes(options.noteMode) ? options.noteMode : DEFAULTS.noteMode,
    appendToolWarnings: booleanOption(options.appendToolWarnings, DEFAULTS.appendToolWarnings),
    mutateUserMessageAtHandoff: booleanOption(
      options.mutateUserMessageAtHandoff,
      DEFAULTS.mutateUserMessageAtHandoff,
    ),
    log: booleanOption(options.log, DEFAULTS.log),
    handoffInstruction: stringOption(options.handoffInstruction, DEFAULTS.handoffInstruction),
  }
}

function estimateTextTokens(text, charsPerToken) {
  if (!text) return 0
  return Math.ceil(String(text).length / charsPerToken)
}

function formatInt(value) {
  if (!Number.isFinite(value)) return "unknown"
  return Math.round(value).toLocaleString("en-US")
}

function getSession(states, sessionID) {
  const id = sessionID || "unknown"
  const existing = states.get(id)
  if (existing) return existing
  const created = {
    sessionID: id,
    lastExactInputTokens: 0,
    lastExactOutputTokens: 0,
    lastExactReasoningTokens: 0,
    pendingEstimatedTokens: 0,
    contextLimit: undefined,
    outputLimit: undefined,
    modelID: undefined,
    providerID: undefined,
    thresholdCrossed: false,
    lastUpdated: Date.now(),
  }
  states.set(id, created)
  return created
}

function estimateCurrent(state) {
  return state.lastExactInputTokens + state.pendingEstimatedTokens
}

function levelFor(estimated, cfg) {
  if (estimated >= cfg.handoffThreshold) return "handoff"
  if (estimated >= cfg.warnThreshold) return "warn"
  if (estimated >= cfg.informThreshold) return "inform"
  return "ok"
}

function shouldInject(level, cfg) {
  if (cfg.noteMode === "always") return true
  if (cfg.noteMode === "warn") return level === "warn" || level === "handoff"
  return level === "handoff"
}

function contextFromModel(model) {
  return {
    contextLimit: model?.limit?.context,
    outputLimit: model?.limit?.output,
    modelID: model?.id || model?.modelID || model?.name,
    providerID: model?.providerID,
  }
}

function budgetNote(state, cfg, source = "system") {
  const estimated = estimateCurrent(state)
  const contextLimit = state.contextLimit
  const usableRemaining = Number.isFinite(contextLimit)
    ? contextLimit - estimated - cfg.reserveOutputTokens
    : undefined
  const level = levelFor(estimated, cfg)
  const header =
    level === "handoff"
      ? "CONTEXT BUDGET HANDOFF REQUIRED"
      : level === "warn"
        ? "CONTEXT BUDGET WARNING"
        : level === "inform"
          ? "CONTEXT BUDGET NOTICE"
          : "CONTEXT BUDGET"
  const action =
    level === "handoff"
      ? `You have crossed the configured handoff threshold. Do not continue normal work. ${cfg.handoffInstruction}`
      : level === "warn"
        ? "You are close to the handoff threshold. Prefer concise tool use and avoid loading large files unless essential."
        : level === "inform"
          ? "Continue normally, but be context-aware and avoid unnecessary large reads."
          : "Continue normally."

  return [
    `<${header.toLowerCase().replaceAll(" ", "_")}>`,
    `Source: ${source}`,
    `Model: ${state.providerID || "unknown"}/${state.modelID || "unknown"}`,
    `Model context window: ${formatInt(contextLimit)} tokens`,
    `Last exact input tokens: ${formatInt(state.lastExactInputTokens)}`,
    `Estimated tokens added since last exact count: ${formatInt(state.pendingEstimatedTokens)}`,
    `Estimated current input context: ${formatInt(estimated)} tokens`,
    `Reserved output budget: ${formatInt(cfg.reserveOutputTokens)} tokens`,
    `Estimated usable remaining context: ${formatInt(usableRemaining)} tokens`,
    `Inform/warn/handoff thresholds: ${formatInt(cfg.informThreshold)} / ${formatInt(cfg.warnThreshold)} / ${formatInt(cfg.handoffThreshold)} tokens`,
    `Policy: ${action}`,
    `</${header.toLowerCase().replaceAll(" ", "_")}>`,
  ].join("\n")
}

function extractStepFinishPart(event) {
  const candidates = [
    event?.properties?.part,
    event?.properties?.message?.part,
    event?.part,
    event?.message?.part,
  ].filter(Boolean)
  return candidates.find((part) => part?.type === "step-finish" && part?.tokens)
}

function extractEventSessionID(event, part) {
  return (
    part?.sessionID ||
    part?.session_id ||
    event?.properties?.sessionID ||
    event?.properties?.session_id ||
    event?.sessionID ||
    event?.session_id
  )
}

async function writeLog(ctx, cfg, line) {
  if (!cfg.log) return
  const file = `${ctx.directory}/.context-governor.log`
  const { appendFile, mkdir } = await import("node:fs/promises")
  await mkdir(ctx.directory, { recursive: true }).catch(() => {})
  await appendFile(file, `${new Date().toISOString()} ${line}\n`).catch(() => {})
}

function updateModelState(state, model) {
  const info = contextFromModel(model)
  state.contextLimit = info.contextLimit ?? state.contextLimit
  state.outputLimit = info.outputLimit ?? state.outputLimit
  state.modelID = info.modelID ?? state.modelID
  state.providerID = info.providerID ?? state.providerID
  state.lastUpdated = Date.now()
}

async function server(ctx, options) {
  const cfg = normalizeOptions(options)
  const states = new Map()

  await writeLog(ctx, cfg, `loaded options=${JSON.stringify(cfg)}`)

  return {
    event: async ({ event }) => {
      if (!cfg.enabled) return
      const part = extractStepFinishPart(event)
      if (!part) return
      const state = getSession(states, extractEventSessionID(event, part))
      state.lastExactInputTokens = part.tokens.input || 0
      state.lastExactOutputTokens = part.tokens.output || 0
      state.lastExactReasoningTokens = part.tokens.reasoning || 0
      // The next request's input will include the assistant result that was just produced.
      state.pendingEstimatedTokens = state.lastExactOutputTokens + state.lastExactReasoningTokens
      state.thresholdCrossed = levelFor(estimateCurrent(state), cfg) === "handoff"
      state.lastUpdated = Date.now()
      await writeLog(
        ctx,
        cfg,
        `step-finish session=${state.sessionID} input=${state.lastExactInputTokens} output=${state.lastExactOutputTokens} reasoning=${state.lastExactReasoningTokens} pending=${state.pendingEstimatedTokens}`,
      )
    },

    "chat.message": async (input, output) => {
      if (!cfg.enabled) return
      const state = getSession(states, input.sessionID)
      const text = (output.parts || [])
        .filter((part) => part?.type === "text")
        .map((part) => part.text || "")
        .join("\n")
      state.pendingEstimatedTokens += estimateTextTokens(text, cfg.estimateCharsPerToken)
      if (input.model) {
        state.providerID = input.model.providerID || state.providerID
        state.modelID = input.model.modelID || state.modelID
      }
      const level = levelFor(estimateCurrent(state), cfg)
      state.thresholdCrossed = level === "handoff"
      if (cfg.mutateUserMessageAtHandoff && level === "handoff") {
        output.message.system = [
          output.message.system,
          budgetNote(state, cfg, "chat.message"),
        ]
          .filter(Boolean)
          .join("\n\n")
      }
      await writeLog(
        ctx,
        cfg,
        `chat.message session=${state.sessionID} added=${estimateTextTokens(text, cfg.estimateCharsPerToken)} estimated=${estimateCurrent(state)} level=${level}`,
      )
    },

    "experimental.chat.system.transform": async (input, output) => {
      if (!cfg.enabled) return
      const state = getSession(states, input.sessionID)
      updateModelState(state, input.model)
      const level = levelFor(estimateCurrent(state), cfg)
      state.thresholdCrossed = level === "handoff"
      if (!shouldInject(level, cfg)) return
      output.system.push(budgetNote(state, cfg, "system.transform"))
      await writeLog(
        ctx,
        cfg,
        `system.transform session=${state.sessionID} estimated=${estimateCurrent(state)} level=${level} context=${state.contextLimit}`,
      )
    },

    "tool.execute.after": async (input, output) => {
      if (!cfg.enabled) return
      const state = getSession(states, input.sessionID)
      const added = estimateTextTokens(output.output || "", cfg.estimateCharsPerToken)
      state.pendingEstimatedTokens += added
      const level = levelFor(estimateCurrent(state), cfg)
      state.thresholdCrossed = level === "handoff"
      await writeLog(
        ctx,
        cfg,
        `tool.after session=${state.sessionID} tool=${input.tool} added=${added} estimated=${estimateCurrent(state)} level=${level}`,
      )
      if (!cfg.appendToolWarnings || level === "ok" || level === "inform") return
      output.output = `${output.output}\n\n${budgetNote(state, cfg, "tool.execute.after")}`
    },
  }
}

export default {
  id: "fed.context-governor",
  server,
}
