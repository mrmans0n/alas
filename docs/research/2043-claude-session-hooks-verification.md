# Claude session hooks verification for issue #2043

Alas sends a session's captured hooks as `_meta.claudeCode.options.settings.hooks` on session/new, session/load, session/resume, and session/fork. This note records the adapter contract and a live run against the published adapter.

## Adapter contract

Verified by reading the published `dist/acp-agent.js` of `@alas-ide/claude-agent-acp@0.94.0-alas.1` (npm integrity `sha512-EEPJ0shdTiFuDMyMHKd6ihn5881cOTb6suQEwNYd2lIO9ShG617Y75Wizx43SMwnvHC5/iTbMZ166pzhZbM34A==`, bundled Claude Agent SDK `0.3.303`). The settings merge is upstream [claude-agent-acp #1265](https://github.com/agentclientprotocol/claude-agent-acp/pull/1265) (`fe8b69e`), first released in v0.90.0. No downstream fork change was needed.

| Method | What the adapter does with `options.settings` |
| --- | --- |
| session/new | Creates the query with it. |
| session/load, not live | Creates the query with it while replaying the transcript. |
| session/load or session/resume, live | Keeps the query when the session fingerprint is unchanged. `settings` is part of the fingerprint, so a different object tears the query down and recreates it. |
| session/fork | Creates the fork's query with it. |

- The adapter merges the object over `CLAUDE_MODEL_CONFIG` (`{...modelConfig, ...settings}`) and passes it to Claude Code as the programmatic settings tier. Alas sends only `hooks`, so `modelOverrides` and `availableModels` stay intact.
- A string `settings` value is read as a file path relative to `cwd`. Alas always sends an object.
- `options.hooks` is the SDK's in-process callback form and cannot cross JSON-RPC. Alas never sends it.
- Alas re-sends the same snapshot on every request, so a live reload keeps its query rather than rebuilding it.

## Live run

Setup:

- The adapter was the global install above, started with `node dist/index.js`.
- `ANTHROPIC_BASE_URL` pointed at a loopback Messages fixture that returns a fixed streamed reply and logs each request's model.
- A scratch `HOME` and `CLAUDE_CONFIG_DIR` were used, with a user-tier `UserPromptSubmit` hook in the scratch config and a project-tier `UserPromptSubmit` hook in the scratch project's `.claude/settings.json`.
- `CLAUDE_MODEL_CONFIG={"availableModels":["opus","haiku"],"modelOverrides":{"claude-opus-5-5":"fixture-override-opus"}}`.
- Every hook appends `<tier> <hook_event_name> <session_id>` to a marker file.

Session A was created with session hooks (`SessionStart` and `UserPromptSubmit`) alongside `disallowedTools`. Session B was created with `disallowedTools` only.

| Step | Markers |
| --- | --- |
| session/new A | `session SessionStart A` |
| prompt A | `user`, `project`, `session` `UserPromptSubmit A`, once each |
| prompt B | `user`, `project` `UserPromptSubmit B`; no session hook |
| restart adapter, session/load A | `session SessionStart A` |
| prompt A | `user`, `project`, `session` `UserPromptSubmit A`, once each |
| session/load A again in the same process | nothing (live query kept) |
| prompt A | `user`, `project`, `session` `UserPromptSubmit A`, once each |

A second run replaced the `UserPromptSubmit` session hook with a relative `./rel-hook.sh` that exists only in the session's project directory. The driver itself ran from `/tmp`. The hook ran once for each of A's three prompts, so Claude Code resolves hook commands against the session's cwd.

All seven provider requests used `fixture-override-opus`. The model option listed `default`, `opus`, and `haiku` for A, for B, and for A after the load. Session hooks therefore ran only for their own session, ran alongside user and project hooks, were neither lost nor duplicated across a restart and a repeated load, and left the model configuration in place.

## Limits

- Not run over SSH. Remote sessions send the same metadata, and the remote adapter runs the hooks on the remote host, in the session worktree. Alas resolves no paths itself.
- A Mac running an Alas build from before this change ignores the replicated `sessionHooks` field when it takes over a session, so it restores that session without the hooks.
