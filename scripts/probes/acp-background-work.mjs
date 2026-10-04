// Throwaway adapter-runtime probe for issue #1744. No model calls or processes.
// Usage: node scripts/probes/acp-background-work.mjs "$(npm root -g)"
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.argv[2];
assert.ok(root, 'Pass the installed npm module directory');
const packageAt = name => join(root, name);
const version = name => JSON.parse(readFileSync(join(packageAt(name), 'package.json'), 'utf8')).version;
const claude = packageAt('@agentclientprotocol/claude-agent-acp');
const codex = packageAt('@agentclientprotocol/codex-acp');
const versions = {
  claude: version('@agentclientprotocol/claude-agent-acp'),
  codex: version('@agentclientprotocol/codex-acp'),
  pi: version('pi-acp'),
};
assert.deepEqual(versions, { claude: '0.85.1', codex: '2.1.1', pi: '0.0.34' },
  'This spike is pinned to the inspected adapter versions; re-inspect before updating it');

const { AsyncTaskRuntime, clientSupportsAsyncTasks } = await import(
  pathToFileURL(join(claude, 'dist/async-tasks.js')));
const capabilities = { _meta: { terminal_output_delta: true,
  jetbrains: { air: { version: 1, capabilities: ['asyncTasks'] } } } };
assert.equal(clientSupportsAsyncTasks({}), false);
assert.equal(clientSupportsAsyncTasks(capabilities), true);
const claudeUpdates = [];
const runtime = new AsyncTaskRuntime(true, 'root', async update => claudeUpdates.push(update),
  { notices: true });
await runtime.taskStarted({ task_id: 'shell-1', task_type: 'local_bash',
  description: 'Sleep and print', is_backgrounded: true, tool_use_id: 'bash-1',
  output_file: '/tmp/shell-1.log' });
await runtime.taskProgress({ task_id: 'shell-1', summary: 'Waiting',
  usage: { total_tokens: 0, tool_uses: 0, duration_ms: 10 } });
await runtime.taskNotification({ task_id: 'shell-1', status: 'completed', summary: 'Printed done' });
await runtime.taskStarted({ task_id: 'monitor-1', task_type: 'monitor',
  description: 'Watch builds', tool_use_id: 'monitor-tool' });
assert.equal(runtime.claimStop('monitor-1'), true);
await runtime.taskStopped('monitor-1');
assert.deepEqual(claudeUpdates.filter(({ update }) => update.sessionUpdate === 'async_task_state_update')
  .map(({ update }) => update.state), ['completed', 'stopped']);

// Codex ships one executable bundle without library exports. Extract only its
// task runtime, then supply an in-memory app-server and publisher. The adapter
// entrypoint is never evaluated, so no Codex process or session is started.
const source = readFileSync(join(codex, 'dist/index.js'), 'utf8');
const begin = source.indexOf('// src/async-tasks/CodexBackgroundTerminalTasks.ts');
const end = source.indexOf('// src/CodexSessionCompactions.ts', begin);
assert.ok(begin >= 0 && end > begin, 'Expected task runtime boundaries in the installed bundle');
const CodexTasks = new Function('logger', 'JETBRAINS_META_KEY', 'AIR_META_KEY',
  'AIR_ASYNC_TASKS_KEY', 'AIR_ASYNC_TASKS_BACKGROUNDED_KEY',
  source.slice(begin, end) + '\nreturn CodexBackgroundTerminalTasks;')(
    { error: () => {} }, 'jetbrains', 'air', 'asyncTasks', 'backgrounded');
const codexUpdates = [];
const terminations = [];
let listed = [{ itemId: 'exec-1', processId: '42', command: 'sleep 60' }];
const appServer = {
  threadBackgroundTerminalsList: async () => ({ data: listed, nextCursor: null }),
  threadBackgroundTerminalsTerminate: async params => {
    terminations.push(params);
    return { terminated: true };
  },
};
const tasks = new CodexTasks(true, 'root', appServer,
  { update: async (update, sessionId) => codexUpdates.push({ sessionId, update }) });
await tasks.reconcile();
assert.equal(await tasks.stop('exec-1'), true);
assert.deepEqual(terminations, [{ threadId: 'root', processId: '42' }]);
listed = [{ itemId: 'exec-2', processId: '43', command: 'sleep 1; echo done' }];
await tasks.reconcile();
await tasks.handleNotification({ method: 'item/completed', params: {
  threadId: 'root', item: { id: 'exec-2', type: 'commandExecution', status: 'completed' },
} }, 'root');
assert.deepEqual(codexUpdates.filter(({ update }) => update.sessionUpdate === 'async_task_state_update')
  .map(({ update }) => update.state), ['stopped', 'completed']);

const { AcpToolCallRenderer } = await import(pathToFileURL(join(claude, 'dist/tool-calls/renderer.js')));
const use = { id: 'bash-1', name: 'Bash', input: { command: 'echo done' } };
const result = { type: 'tool_result', tool_use_id: 'bash-1', content: 'done', is_error: false };
const toolReports = Object.fromEntries([
  ['default', { _meta: { terminal_output: true } }], ['asyncTasks', capabilities],
].map(([name, caps]) => {
  const renderer = AcpToolCallRenderer.for(caps);
  return [name, {
    start: renderer.toolCall(use, { cwd: '/tmp', inputComplete: true }),
    finish: renderer.result(use, result),
  }];
}));
assert.equal(toolReports.asyncTasks.finish.at(-1).status, 'completed');
assert.equal(toolReports.asyncTasks.finish[0]._meta.terminal_output_delta.data, 'done');

console.log(JSON.stringify({ versions, claudeUpdates, codexUpdates, terminations, toolReports }, null, 2));
