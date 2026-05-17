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
  autoContinue: "off",
  autoContinueSubagents: "prepare-only",
  autoContinueSelectTui: true,
  autoContinueSelectTuiForSubagents: false,
  autoContinueMaxChain: 3,
  autoContinueHandoffMarker: "CONTEXT_GOVERNOR_HANDOFF",
  autoContinueStateFile: ".context-governor-handoffs.jsonl",
  autoContinueTitlePrefix: "Context Governor continuation",
  autoContinueInstruction:
    "Continue from the handoff below. Preserve decisions and state, verify before making changes, and proceed with the next concrete step.",
  handoffInstruction:
    "Write a handoff letter and stop. Put CONTEXT_GOVERNOR_HANDOFF on its own line, then include current goal, repo state, files touched, important decisions, commands run, test status, risks, and exact next steps.",
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

function normalizeAutoContinueMode(value) {
  return ["off", "prepare-only", "prompt-async"].includes(value) ? value : DEFAULTS.autoContinue
}

function normalizeSubagentAutoContinueMode(value) {
  return ["inherit", "off", "prepare-only", "prompt-async"].includes(value)
    ? value
    : DEFAULTS.autoContinueSubagents
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
    autoContinue: normalizeAutoContinueMode(options.autoContinue),
    autoContinueSubagents: normalizeSubagentAutoContinueMode(options.autoContinueSubagents),
    autoContinueSelectTui: booleanOption(options.autoContinueSelectTui, DEFAULTS.autoContinueSelectTui),
    autoContinueSelectTuiForSubagents: booleanOption(
      options.autoContinueSelectTuiForSubagents,
      DEFAULTS.autoContinueSelectTuiForSubagents,
    ),
    autoContinueMaxChain: Math.max(0, Math.floor(numberOption(options.autoContinueMaxChain, DEFAULTS.autoContinueMaxChain))),
    autoContinueHandoffMarker: stringOption(
      options.autoContinueHandoffMarker,
      DEFAULTS.autoContinueHandoffMarker,
    ),
    autoContinueStateFile: stringOption(options.autoContinueStateFile, DEFAULTS.autoContinueStateFile),
    autoContinueTitlePrefix: stringOption(options.autoContinueTitlePrefix, DEFAULTS.autoContinueTitlePrefix),
    autoContinueInstruction: stringOption(options.autoContinueInstruction, DEFAULTS.autoContinueInstruction),
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
    handoffRequested: false,
    handoffMarkerSeen: false,
    handoffText: "",
    assistantFinished: false,
    continuationStarted: false,
    childSessionID: undefined,
    chainDepth: 0,
    kind: "orchestrator",
    parentSessionID: undefined,
    agent: undefined,
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

function isSubagentSession(state) {
  return state?.kind === "subagent"
}

function effectiveAutoContinueMode(cfg, state) {
  if (!isSubagentSession(state)) return cfg.autoContinue
  return cfg.autoContinueSubagents === "inherit" ? cfg.autoContinue : cfg.autoContinueSubagents
}

function shouldSelectTuiForSession(cfg, state) {
  if (!cfg.autoContinueSelectTui) return false
  if (isSubagentSession(state)) return cfg.autoContinueSelectTuiForSubagents
  return true
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
    part?.message?.sessionID ||
    part?.message?.session_id ||
    event?.properties?.sessionID ||
    event?.properties?.session_id ||
    event?.properties?.session?.id ||
    event?.properties?.message?.sessionID ||
    event?.properties?.message?.session_id ||
    event?.properties?.part?.sessionID ||
    event?.properties?.part?.session_id ||
    event?.sessionID ||
    event?.session_id ||
    event?.session?.id ||
    event?.message?.sessionID ||
    event?.message?.session_id
  )
}

function eventType(event) {
  return String(
    event?.type ||
      event?.name ||
      event?.event ||
      event?.properties?.type ||
      event?.properties?.name ||
      event?.properties?.event ||
      "",
  )
}

function firstString(...values) {
  return values.find((value) => typeof value === "string" && value.trim())
}

function hasExplicitSubagentFlag(...values) {
  return values.some((value) => value === true || value === "true" || value === "subagent" || value === "subtask")
}

function markSubagentState(state, parentSessionID) {
  if (!state || state.kind === "continuation-child") return false
  state.kind = "subagent"
  state.parentSessionID = parentSessionID || state.parentSessionID
  state.lastUpdated = Date.now()
  return true
}

function markSubagentSession(states, sessionID, parentSessionID) {
  if (!sessionID) return false
  return markSubagentState(getSession(states, sessionID), parentSessionID)
}

function markSubagentFromExplicitFlags(states, state, input, event) {
  const props = event?.properties || {}
  const flagged = hasExplicitSubagentFlag(
    input?.subtask,
    input?.subagent,
    input?.command?.subtask,
    input?.command?.subagent,
    input?.session?.subtask,
    input?.session?.subagent,
    props.subtask,
    props.subagent,
    props.session?.subtask,
    props.session?.subagent,
    props.info?.subtask,
    props.info?.subagent,
    event?.subtask,
    event?.subagent,
  )
  return flagged ? markSubagentState(state, firstString(input?.parentSessionID, input?.parentID, props.parentSessionID, props.parentID)) : false
}

function markSubagentFromTaskTool(states, input, output) {
  if (input?.tool !== "task") return false
  const childSessionID = firstString(
    output?.metadata?.sessionId,
    output?.metadata?.sessionID,
    output?.metadata?.session_id,
    output?.metadata?.session?.id,
  )
  const parentSessionID = firstString(
    output?.metadata?.parentSessionId,
    output?.metadata?.parentSessionID,
    output?.metadata?.parent_session_id,
    input?.sessionID,
    input?.session_id,
  )
  return markSubagentSession(states, childSessionID, parentSessionID)
}

function markSubagentFromTaskPart(states, event) {
  const props = event?.properties || {}
  const part = props.part || props.message?.part || event?.part || event?.message?.part
  const tool = part?.tool || part?.name || part?.input?.tool || part?.state?.input?.tool
  if (tool !== "task") return false
  const childSessionID = firstString(
    part?.state?.metadata?.sessionId,
    part?.state?.metadata?.sessionID,
    part?.state?.metadata?.session_id,
    part?.metadata?.sessionId,
    part?.metadata?.sessionID,
    part?.metadata?.session_id,
  )
  const parentSessionID = firstString(
    part?.state?.metadata?.parentSessionId,
    part?.state?.metadata?.parentSessionID,
    part?.metadata?.parentSessionId,
    part?.metadata?.parentSessionID,
    props.sessionID,
    props.session_id,
    event?.sessionID,
    event?.session_id,
  )
  return markSubagentSession(states, childSessionID, parentSessionID)
}

function isAssistantRole(value) {
  return value?.role === "assistant" || value?.message?.role === "assistant"
}

function textFromPart(part) {
  if (!part || typeof part !== "object") return ""
  const type = String(part.type || "")
  const looksLikeText = !type || type.includes("text") || type.includes("content") || type.includes("delta")
  if (!looksLikeText) return ""
  return [part.text, part.delta, part.content]
    .filter((value) => typeof value === "string")
    .join("")
}

function extractAssistantText(event) {
  const candidates = [
    event?.properties?.part,
    event?.properties?.message?.part,
    event?.part,
    event?.message?.part,
  ].filter(Boolean)

  const messages = [event?.properties?.message, event?.message].filter(Boolean)
  for (const message of messages) {
    if (Array.isArray(message.parts)) candidates.push(...message.parts)
    if (isAssistantRole(message) && typeof message.text === "string") candidates.push({ type: "text", text: message.text })
    if (isAssistantRole(message) && typeof message.content === "string") candidates.push({ type: "text", text: message.content })
  }

  return candidates.map(textFromPart).filter(Boolean).join("")
}

function isAssistantFinishedEvent(event, part) {
  const type = eventType(event).toLowerCase()
  if (part?.type === "step-finish") return true
  if (type.includes("session.idle") || type.includes("session_idle")) return true
  if (type.includes("step.finish") || type.includes("step-finish")) return true

  const messages = [event?.properties?.message, event?.message].filter(Boolean)
  return messages.some((message) => {
    const status = String(message.status || message.state || "").toLowerCase()
    return isAssistantRole(message) && ["completed", "complete", "done", "finished"].includes(status)
  })
}

function compactHandoffText(text, marker) {
  const value = String(text || "").trim()
  if (!value) return marker
  const markerIndex = value.indexOf(marker)
  const selected = markerIndex >= 0 ? value.slice(markerIndex) : value
  return selected.length > 40_000 ? selected.slice(selected.length - 40_000) : selected
}

function stateFilePath(ctx, cfg) {
  return cfg.autoContinueStateFile.startsWith("/")
    ? cfg.autoContinueStateFile
    : `${ctx.directory}/${cfg.autoContinueStateFile}`
}

async function appendJsonl(ctx, cfg, record) {
  const { appendFile, mkdir } = await import("node:fs/promises")
  await mkdir(ctx.directory, { recursive: true }).catch(() => {})
  await appendFile(stateFilePath(ctx, cfg), `${JSON.stringify(record)}\n`).catch(() => {})
}

function buildContinuationPrompt(cfg, state) {
  return [
    cfg.autoContinueInstruction,
    "",
    `Previous session ID: ${state.sessionID}`,
    `Continuation chain depth: ${state.chainDepth + 1}`,
    "",
    "Handoff from previous assistant response:",
    "```text",
    compactHandoffText(state.handoffText, cfg.autoContinueHandoffMarker),
    "```",
  ].join("\n")
}

function childSessionIDFromCreate(result) {
  return result?.id || result?.sessionID || result?.session?.id || result?.data?.id || result?.data?.sessionID || result?.data?.session?.id
}

async function selectTuiSession(ctx, cfg, state, sessionID) {
  if (!shouldSelectTuiForSession(cfg, state) || !sessionID) return
  try {
    const response = await ctx.client?._client?.post?.({
      url: "/tui/select-session",
      query: { directory: ctx.directory },
      body: { sessionID },
    })
    await writeLog(ctx, cfg, `auto-continue tui-select child=${sessionID} data=${JSON.stringify(response?.data ?? response)}`)
  } catch (error) {
    await writeLog(ctx, cfg, `auto-continue tui-select failed child=${sessionID} error=${error?.message || error}`)
  }
}

async function createContinuationSession(ctx, cfg, states, state) {
  const mode = effectiveAutoContinueMode(cfg, state)
  const title = `${cfg.autoContinueTitlePrefix}: ${state.sessionID}`
  const noReply = mode === "prepare-only"
  const record = {
    time: new Date().toISOString(),
    mode,
    parentSessionID: state.sessionID,
    parentKind: state.kind,
    sourceParentSessionID: state.parentSessionID,
    chainDepth: state.chainDepth,
    marker: cfg.autoContinueHandoffMarker,
  }

  try {
    const created = await ctx.client.session.create({
      query: { directory: ctx.directory },
      body: { parentID: state.sessionID, title },
    })
    const childID = childSessionIDFromCreate(created)
    if (!childID) throw new Error("OpenCode did not return a child session id")
    state.childSessionID = childID

    const childState = getSession(states, childID)
    childState.chainDepth = state.chainDepth + 1
    childState.kind = "continuation-child"
    childState.parentSessionID = state.sessionID

    await selectTuiSession(ctx, cfg, state, childID)

    const body = {
      noReply,
      parts: [{ type: "text", text: buildContinuationPrompt(cfg, state) }],
    }
    if (state.agent) body.agent = state.agent
    await ctx.client.session.promptAsync({
      path: { id: childID },
      query: { directory: ctx.directory },
      body,
    })
    await selectTuiSession(ctx, cfg, state, childID)

    await appendJsonl(ctx, cfg, { ...record, childSessionID: childID, noReply, status: "created" })
    await writeLog(ctx, cfg, `auto-continue created parent=${state.sessionID} child=${childID} parentKind=${state.kind} mode=${mode} noReply=${noReply}`)
  } catch (error) {
    await appendJsonl(ctx, cfg, { ...record, status: "failed", error: String(error?.message || error) })
    await writeLog(ctx, cfg, `auto-continue failed parent=${state.sessionID} error=${error?.message || error}`)
  }
}

async function maybeStartContinuation(ctx, cfg, states, state) {
  const mode = effectiveAutoContinueMode(cfg, state)
  if (mode === "off") return
  if (!state.handoffRequested || !state.handoffMarkerSeen || !state.assistantFinished) return
  if (state.continuationStarted) return
  if (state.chainDepth >= cfg.autoContinueMaxChain) {
    await writeLog(ctx, cfg, `auto-continue max-chain parent=${state.sessionID} depth=${state.chainDepth} max=${cfg.autoContinueMaxChain}`)
    return
  }
  state.continuationStarted = true
  await writeLog(ctx, cfg, `auto-continue trigger parent=${state.sessionID} kind=${state.kind} depth=${state.chainDepth} mode=${mode}`)
  await createContinuationSession(ctx, cfg, states, state)
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
      markSubagentFromTaskPart(states, event)
      const state = getSession(states, extractEventSessionID(event, part))
      markSubagentFromExplicitFlags(states, state, undefined, event)

      if (state.handoffRequested) {
        const text = extractAssistantText(event)
        if (text) {
          state.handoffText += text
          if (!state.handoffMarkerSeen && state.handoffText.includes(cfg.autoContinueHandoffMarker)) {
            state.handoffMarkerSeen = true
            await writeLog(ctx, cfg, `auto-continue marker-seen session=${state.sessionID}`)
          }
        }
        if (state.handoffMarkerSeen && isAssistantFinishedEvent(event, part)) {
          state.assistantFinished = true
          await writeLog(ctx, cfg, `auto-continue assistant-finished session=${state.sessionID} event=${eventType(event)}`)
        }
      }

      if (part) {
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
      }

      await maybeStartContinuation(ctx, cfg, states, state)
    },

    "chat.message": async (input, output) => {
      if (!cfg.enabled) return
      const state = getSession(states, input.sessionID)
      markSubagentFromExplicitFlags(states, state, input)
      const text = (output.parts || [])
        .filter((part) => part?.type === "text")
        .map((part) => part.text || "")
        .join("\n")
      state.pendingEstimatedTokens += estimateTextTokens(text, cfg.estimateCharsPerToken)
      if (input.model) {
        state.providerID = input.model.providerID || state.providerID
        state.modelID = input.model.modelID || state.modelID
      }
      state.agent = input.agent || input.agentID || input.agentName || state.agent
      const level = levelFor(estimateCurrent(state), cfg)
      state.thresholdCrossed = level === "handoff"
      if (level === "handoff" && !state.handoffRequested) {
        state.handoffRequested = true
        await writeLog(ctx, cfg, `auto-continue requested session=${state.sessionID} source=chat.message`)
      }
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
      markSubagentFromExplicitFlags(states, state, input)
      updateModelState(state, input.model)
      state.agent = input.agent || input.agentID || input.agentName || state.agent
      const level = levelFor(estimateCurrent(state), cfg)
      state.thresholdCrossed = level === "handoff"
      if (level === "handoff" && !state.handoffRequested) {
        state.handoffRequested = true
        await writeLog(ctx, cfg, `auto-continue requested session=${state.sessionID} source=system.transform`)
      }
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
      markSubagentFromExplicitFlags(states, state, input)
      markSubagentFromTaskTool(states, input, output)
      const added = estimateTextTokens(output.output || "", cfg.estimateCharsPerToken)
      state.pendingEstimatedTokens += added
      const level = levelFor(estimateCurrent(state), cfg)
      state.thresholdCrossed = level === "handoff"
      if (level === "handoff" && !state.handoffRequested) {
        state.handoffRequested = true
        await writeLog(ctx, cfg, `auto-continue requested session=${state.sessionID} source=tool.execute.after`)
      }
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
