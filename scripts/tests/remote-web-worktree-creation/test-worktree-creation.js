const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/worktree-creation.js");

const creation = globalThis.RemoteWorktreeCreation;

function newFlow() {
  const commands = [];
  const flow = creation.createFlow((command) => commands.push(command));
  return { flow, commands };
}

{
  const { flow, commands } = newFlow();
  const snapshots = [];
  const unsubscribe = flow.subscribe((snapshot) => snapshots.push(snapshot));

  flow.loadProjects();
  assert.equal(flow.snapshot().projectsLoading, true);
  assert.deepStrictEqual(commands, [{ type: "listProjects" }]);

  flow.receive({
    type: "projectList",
    projects: [{ id: "project-1", name: "First" }, { id: "project-2", name: "Second" }],
  });

  assert.equal(flow.snapshot().projectId, "project-1");
  assert.equal(flow.snapshot().branchesLoading, true);
  assert.deepStrictEqual(commands[1], { type: "listBranches", projectId: "project-1" });
  assert.ok(snapshots.length >= 2);
  unsubscribe();
  const snapshotCount = snapshots.length;
  flow.setBranch("feature/ignored-after-unsubscribe");
  assert.equal(snapshots.length, snapshotCount);
}

{
  const { flow, commands } = newFlow();
  flow.receive({
    type: "projectList",
    projects: [{ id: "project-1", name: "First" }, { id: "project-2", name: "Second" }],
  });
  flow.selectProject("project-2");

  const beforeStaleResponse = flow.snapshot();
  flow.receive({
    type: "branchList",
    projectId: "project-1",
    branches: ["main"],
    preferredBase: "main",
  });
  assert.deepStrictEqual(flow.snapshot(), beforeStaleResponse);

  flow.receive({
    type: "branchList",
    projectId: "project-2",
    branches: ["main", "release"],
    preferredBase: "release",
  });
  assert.equal(flow.snapshot().base, "release");
  assert.deepStrictEqual(flow.snapshot().branches, ["main", "release"]);

  const beforeStaleFailure = flow.snapshot();
  flow.receive({
    type: "branchListFailed",
    projectId: "project-1",
    message: "Old repository failed to load",
  });
  assert.deepStrictEqual(flow.snapshot(), beforeStaleFailure);

  flow.setBase("main");
  flow.selectProject("project-1");
  flow.receive({
    type: "branchList",
    projectId: "project-1",
    branches: ["trunk"],
    preferredBase: "missing",
  });
  assert.equal(flow.snapshot().base, "trunk");
  assert.deepStrictEqual(commands.at(-1), { type: "listBranches", projectId: "project-1" });
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({
    type: "branchListFailed",
    projectId: "project-1",
    message: "Git is unavailable",
  });
  assert.equal(flow.snapshot().projectId, "project-1");
  assert.equal(flow.snapshot().branchesLoading, false);
  assert.deepStrictEqual(flow.snapshot().error, { stage: "branches", message: "Git is unavailable", worktreeId: null });

  flow.retryBranches();
  assert.deepStrictEqual(commands.at(-1), { type: "listBranches", projectId: "project-1" });
  assert.equal(flow.snapshot().branchesLoading, true);
}

{
  const { flow, commands } = newFlow();
  flow.startNewWorktree();
  flow.loadProjects();
  flow.reloadCatalog();
  assert.deepStrictEqual(commands, [
    { type: "listProjects" },
    { type: "listProjects" },
  ]);

  flow.receive({ type: "projectList", projects: [{ id: "project-1", name: "First" }] });
  assert.deepStrictEqual(commands.at(-1), { type: "listBranches", projectId: "project-1" });
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  assert.equal(flow.snapshot().projectsLoading, false);
  assert.equal(flow.snapshot().branchesLoading, false);
  assert.equal(flow.snapshot().branchStatus, "loaded");
}

{
  const { flow, commands } = newFlow();
  flow.startNewWorktree();
  flow.receive({ type: "projectList", projects: [{ id: "project-1", name: "First" }] });
  flow.reloadCatalog();
  assert.deepStrictEqual(commands.slice(-2), [
    { type: "listProjects" },
    { type: "listBranches", projectId: "project-1" },
  ]);
  assert.equal(flow.snapshot().projectsLoading, true);
  assert.equal(flow.snapshot().branchesLoading, true);

  flow.receive({ type: "projectList", projects: [{ id: "project-1", name: "First" }] });
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  assert.equal(flow.snapshot().projectsLoading, false);
  assert.equal(flow.snapshot().branchesLoading, false);
  assert.equal(flow.snapshot().base, "main");
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/stale-agent");
  flow.setAgent("agent-stale");
  assert.equal(flow.canSubmit(), true);
  assert.equal(flow.reconcileAgents([{ id: "agent-current" }]), true);
  assert.equal(flow.snapshot().agentId, null);
  assert.equal(flow.canSubmit(), false);
  assert.equal(flow.submit(), false);
  assert.equal(commands.filter(({ type }) => type === "createWorktreeSession").length, 0);
}

{
  const { flow, commands } = newFlow();
  assert.equal(flow.submit(), false);
  assert.equal(flow.snapshot().error.stage, "validation");

  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("   ");
  flow.setAgent("agent-1");
  assert.equal(flow.canSubmit(), false);
  assert.equal(flow.submit(), false);

  flow.setBranch("feature/new-worktree");
  assert.equal(flow.canSubmit(), true);
  assert.equal(flow.submit(), true);
  assert.equal(flow.submit(), false);
  assert.equal(flow.snapshot().submitting, true);
  assert.deepStrictEqual(commands.at(-1), {
    type: "createWorktreeSession",
    projectId: "project-1",
    base: "main",
    branch: "feature/new-worktree",
    agentId: "agent-1",
  });
  assert.equal(commands.filter(({ type }) => type === "createWorktreeSession").length, 1);
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/validation");

  assert.equal(flow.submit(), false);
  assert.equal(flow.snapshot().error.stage, "validation");
  assert.equal(commands.filter(({ type }) => type === "createWorktreeSession").length, 0);

  flow.setAgent("agent-1");
  flow.setBase("missing");
  assert.equal(flow.submit(), false);
  assert.equal(flow.snapshot().error.stage, "validation");
  assert.equal(commands.filter(({ type }) => type === "createWorktreeSession").length, 0);
}

assert.equal(creation.isValidBranchName("feature/new-worktree"), true);
assert.equal(creation.isValidBranchName("feature\u0001broken"), false);

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/ok");
  flow.setAgent("agent-1");
  flow.submit();
  const session = { id: "session-1", title: "New session", worktree: { id: "worktree-1" } };
  flow.receive({ type: "worktreeSessionCreated", session });
  assert.equal(flow.snapshot().submitting, false);
  assert.deepStrictEqual(flow.snapshot().result, session);
  assert.equal(flow.snapshot().error, null);

  const completedCommands = commands.length;
  flow.receive({ type: "branchList", projectId: "project-other", branches: ["main"], preferredBase: "main" });
  assert.equal(commands.length, completedCommands);

  const completedSnapshot = flow.snapshot();
  completedSnapshot.result.worktree.id = "mutated";
  assert.equal(flow.snapshot().result.worktree.id, "worktree-1");
}

{
  const { flow, commands } = newFlow();
  const observedBranches = [];
  flow.subscribe((snapshot) => snapshot.branches.push("mutated"));
  flow.subscribe((snapshot) => observedBranches.push(snapshot.branches));
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  assert.deepStrictEqual(observedBranches.at(-1), ["main"]);
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/fail");
  flow.setAgent("agent-1");
  flow.submit();
  const commandsBeforeWorktreeFailure = commands.length;
  flow.receive({ type: "worktreeSessionCreationFailed", stage: "worktree", message: "Branch already exists" });
  assert.equal(commands.length, commandsBeforeWorktreeFailure);
  assert.equal(flow.snapshot().submitting, false);
  assert.deepStrictEqual(flow.snapshot().error, {
    stage: "worktree", message: "Branch already exists", worktreeId: null,
  });

  flow.submit();
  const commandsBeforeSessionFailure = commands.length;
  flow.receive({
    type: "worktreeSessionCreationFailed",
    stage: "session",
    message: "Agent failed to start",
    worktreeId: "worktree-1",
  });
  assert.equal(commands.length, commandsBeforeSessionFailure);
  assert.deepStrictEqual(flow.snapshot().error, {
    stage: "session", message: "Agent failed to start", worktreeId: "worktree-1",
  });
  assert.equal(flow.snapshot().result, null);
}

{
  const { flow } = newFlow();
  flow.startNewWorktree();
  assert.equal(flow.snapshot().mode, "new");
  assert.equal(flow.snapshot().step, "worktree");
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/navigation");
  assert.equal(flow.canAdvance(), true);
  assert.equal(flow.next(), true);
  assert.equal(flow.snapshot().step, "agent");
  flow.setAgent("agent-1");
  assert.equal(flow.back(), true);
  assert.equal(flow.snapshot().step, "worktree");
  assert.equal(flow.snapshot().branch, "feature/navigation");
  assert.equal(flow.snapshot().agentId, "agent-1");
  assert.equal(flow.next(), true);
  assert.equal(flow.snapshot().step, "agent");
}

{
  const { flow } = newFlow();
  assert.equal(flow.canAdvance(), false);
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/advance");
  assert.equal(flow.canAdvance(), true);
  flow.startNewWorktree();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/advance");
  flow.setAgent("agent-1");
  flow.submit();
  assert.equal(flow.canAdvance(), false);
}

{
  const { flow } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  const loaded = flow.snapshot();
  assert.equal(flow.receive({ type: "branchList", projectId: "project-1", branches: ["other"], preferredBase: "other" }), false);
  assert.deepStrictEqual(flow.snapshot(), loaded);
  assert.equal(flow.receive({ type: "branchListFailed", projectId: "project-1", message: "late failure" }), false);
  assert.deepStrictEqual(flow.snapshot(), loaded);
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/disconnect");
  flow.setAgent("agent-1");
  assert.equal(flow.submit(), true);
  const commandsBeforeDisconnect = commands.length;
  flow.disconnect();
  assert.equal(flow.snapshot().outcomeUnknown, true);
  assert.equal(flow.snapshot().submitting, false);
  assert.equal(flow.canRetry(), false);
  assert.equal(flow.submit(), false);
  assert.equal(commands.length, commandsBeforeDisconnect);
  assert.equal(flow.receive({ type: "worktreeSessionCreated", session: { id: "late" } }), false);
  assert.equal(flow.snapshot().result, null);
  flow.markRecoveryListLoaded("sessions");
  assert.equal(flow.canRetry(), false);
  flow.markRecoveryListLoaded("worktrees");
  assert.equal(flow.canRetry(), true);
}

{
  const { flow, commands } = newFlow();
  flow.startNewWorktree();
  flow.selectProject("project-1");
  flow.receive({
    type: "branchList",
    projectId: "project-1",
    branches: ["main", "release"],
    preferredBase: "main",
  });
  flow.setBase("release");
  flow.setBranch("feature/reload-preserves-base");
  flow.next();
  flow.setAgent("agent-1");
  flow.submit();
  flow.disconnect();
  const unknownError = flow.snapshot().error;

  flow.reloadCatalog();
  assert.equal(flow.snapshot().base, "release");
  assert.deepStrictEqual(flow.snapshot().error, unknownError);
  assert.deepStrictEqual(commands.slice(-2), [
    { type: "listProjects" },
    { type: "listBranches", projectId: "project-1" },
  ]);

  flow.receive({ type: "projectList", projects: [{ id: "project-1", name: "First" }] });
  flow.receive({
    type: "branchList",
    projectId: "project-1",
    branches: ["main", "release"],
    preferredBase: "main",
  });
  assert.equal(flow.snapshot().base, "release");
  assert.deepStrictEqual(flow.snapshot().error, unknownError);

  flow.markRecoveryListLoaded("sessions");
  flow.markRecoveryListLoaded("worktrees");
  assert.equal(flow.submit(), true);
  assert.deepStrictEqual(commands.at(-1), {
    type: "createWorktreeSession",
    projectId: "project-1",
    base: "release",
    branch: "feature/reload-preserves-base",
    agentId: "agent-1",
  });
}

{
  const { flow } = newFlow();
  flow.startNewWorktree();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/recovery-guard");
  flow.next();
  flow.setAgent("agent-1");
  flow.submit();
  flow.disconnect();

  const recoveryPending = flow.snapshot();
  assert.equal(flow.back(), false);
  assert.deepStrictEqual(flow.reset(), recoveryPending);

  flow.markRecoveryListLoaded("sessions");
  flow.markRecoveryListLoaded("worktrees");
  assert.equal(flow.canRetry(), true);
  assert.deepStrictEqual(flow.reset(), creation.initialState());
}

{
  const { flow } = newFlow();
  flow.startNewWorktree();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/partial");
  flow.next();
  flow.setAgent("agent-1");
  flow.submit();
  assert.equal(flow.receive({
    type: "worktreeSessionCreationFailed",
    stage: "session",
    message: "Agent failed to start",
    worktreeId: "worktree-1",
  }), true);
  assert.equal(flow.snapshot().mode, "existing");
  assert.equal(flow.snapshot().step, "worktree");
  assert.equal(flow.snapshot().createdWorktreeId, "worktree-1");
  assert.equal(flow.snapshot().selectedWorktreeId, "worktree-1");
  const partialSuccess = flow.snapshot();
  assert.equal(flow.receive({ type: "worktreeSessionCreated", session: { id: "duplicate" } }), false);
  assert.deepStrictEqual(flow.snapshot(), partialSuccess);
}

{
  const { flow, commands } = newFlow();
  const observed = [];
  flow.subscribe(() => { throw new Error("listener failed"); });
  flow.subscribe((snapshot) => observed.push(snapshot.projectId));
  flow.selectProject("project-1");
  assert.deepStrictEqual(commands, [{ type: "listBranches", projectId: "project-1" }]);
  assert.deepStrictEqual(observed, ["project-1"]);
}

{
  const { flow, commands } = newFlow();
  let reentered = false;
  flow.subscribe((snapshot) => {
    if (snapshot.projectId === "project-1" && !reentered) {
      reentered = true;
      flow.selectProject("project-2");
    }
  });
  flow.selectProject("project-1");
  assert.deepStrictEqual(commands, [{ type: "listBranches", projectId: "project-2" }]);
  assert.equal(flow.snapshot().projectId, "project-2");
  assert.equal(flow.snapshot().branchStatus, "loading");
}

{
  const { flow } = newFlow();
  const received = [];
  flow.subscribe(() => flow.subscribe(() => received.push("late listener")));
  flow.selectProject("project-1");
  assert.deepStrictEqual(received, []);
  flow.setBranch("feature/next-event");
  assert.deepStrictEqual(received, ["late listener"]);
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/captured");
  flow.setAgent("agent-1");
  let reentered = false;
  flow.subscribe((snapshot) => {
    if (snapshot.submitting && !reentered) {
      reentered = true;
      flow.setBranch("   ");
    }
  });
  assert.equal(flow.submit(), true);
  assert.deepStrictEqual(commands.at(-1), {
    type: "createWorktreeSession",
    projectId: "project-1",
    base: "main",
    branch: "feature/captured",
    agentId: "agent-1",
  });
}

{
  const { flow } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/terminal-validation");
  flow.setAgent("agent-1");
  flow.submit();
  assert.equal(flow.receive({ type: "worktreeSessionCreated", session: {} }), false);
  assert.equal(flow.snapshot().submitting, true);
  assert.equal(flow.receive({ type: "worktreeSessionCreationFailed", stage: "unexpected", message: "bad stage" }), false);
  assert.equal(flow.snapshot().submitting, true);
  assert.equal(flow.receive({ type: "worktreeSessionCreationFailed", stage: "worktree", message: "   " }), false);
  assert.equal(flow.snapshot().submitting, true);
}

{
  const { flow, commands } = newFlow();
  flow.selectProject("project-1");
  flow.receive({ type: "branchList", projectId: "project-1", branches: ["main"], preferredBase: "main" });
  flow.setBranch("feature/retry");
  flow.setAgent("agent-1");
  flow.submit();
  flow.disconnect();
  flow.markRecoveryListLoaded("sessions");
  flow.markRecoveryListLoaded("worktrees");
  assert.equal(flow.canRetry(), true);
  assert.equal(flow.submit(), true);
  assert.equal(commands.filter(({ type }) => type === "createWorktreeSession").length, 2);
  assert.equal(flow.snapshot().outcomeUnknown, false);
  assert.deepStrictEqual(flow.snapshot().recovery, { sessions: false, worktrees: false });
}

{
  const { flow } = newFlow();
  flow.startNewWorktree();
  flow.selectProject("project-1");
  flow.setBranch("feature/clear-on-close");
  flow.setAgent("agent-1");
  flow.reset();
  assert.deepStrictEqual(flow.snapshot(), creation.initialState());
}

console.log("remote web worktree creation tests passed");
