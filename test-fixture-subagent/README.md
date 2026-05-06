# Subagent smoke fixture

This fixture is for testing whether OpenCode Context Governor hooks also run inside sessions created by OpenCode's Task tool for subagents.

The thresholds are low enough that the primary agent's short prompt should stay below handoff, while a deliberately large Task prompt should push the subagent session over the handoff threshold.
