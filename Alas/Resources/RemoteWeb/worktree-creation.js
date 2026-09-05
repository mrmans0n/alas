function initialState() {
  return {
    mode: "existing",
    step: "worktree",
    projectsLoading: false,
    projects: [],
    projectId: null,
    branchesLoading: false,
    branchStatus: "idle",
    branches: [],
    preferredBase: "",
    branchError: "",
    base: "",
    branch: "",
    agentId: null,
    submitting: false,
    error: null,
    result: null,
    outcomeUnknown: false,
    recovery: { sessions: false, worktrees: false },
    createdWorktreeId: null,
    selectedWorktreeId: null,
  };
}

function stringValue(value) {
  return typeof value === "string" ? value : "";
}

function hasText(value) {
  return stringValue(value).trim().length > 0;
}

function isValidBranchName(value) {
  const name = stringValue(value);
  if (!hasText(name) || name.length > 250 || name.includes(" ") || /[\x00-\x1f\x7f]/.test(name)) return false;
  if (name.startsWith("/") || name.endsWith("/") || name.includes("//") || name.includes("@{") || name === "@" || name.startsWith("-")) return false;

  return name.split("/").every((component, index, components) => {
    if (!component || component === "." || component === ".." || component.startsWith(".")) return false;
    if (component.includes("..") || component.endsWith(".lock")) return false;
    if (index === components.length - 1 && component.endsWith(".")) return false;
    return !/[~^:\\?*\[\t\r\n]/.test(component);
  });
}

function canRetry(state) {
  return state.outcomeUnknown &&
    !state.submitting &&
    state.recovery.sessions &&
    state.recovery.worktrees;
}

function canSubmit(state) {
  return !state.submitting &&
    (!state.outcomeUnknown || canRetry(state)) &&
    hasText(state.projectId) &&
    state.branchStatus === "loaded" &&
    state.branches.includes(state.base) &&
    isValidBranchName(state.branch) &&
    hasText(state.agentId);
}

function copyValue(value) {
  if (Array.isArray(value)) return value.map(copyValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, copyValue(entry)]));
  }
  return value;
}

function isUsableSession(session) {
  return session && typeof session === "object" && !Array.isArray(session) && hasText(session.id);
}

function isCreationFailure(message) {
  return (message.stage === "worktree" || message.stage === "session") && hasText(message.message);
}

function snapshotOf(state) {
  return {
    ...state,
    projects: copyValue(state.projects),
    branches: [...state.branches],
    error: state.error ? { ...state.error } : null,
    result: copyValue(state.result),
    recovery: { ...state.recovery },
  };
}

function createFlow(sendCommand) {
  const send = typeof sendCommand === "function" ? sendCommand : () => {};
  let state = initialState();
  let branchRequestGeneration = 0;
  const subscribers = new Set();

  function snapshot() {
    return snapshotOf(state);
  }

  function publish(nextState) {
    state = nextState;
    [...subscribers].forEach((subscriber) => {
      try {
        subscriber(snapshot());
      } catch (_) {
        // A rendering callback must not block the state transition or transport command.
      }
    });
    return snapshot();
  }

  function update(changes) {
    return publish({ ...state, ...changes });
  }

  function emit(command) {
    send({ ...command });
  }

  function clearError() {
    return state.error ? { error: null } : {};
  }

  function loadBranches(projectId) {
    const selectedProjectId = hasText(projectId) ? projectId : null;
    if (!selectedProjectId) {
      return update({
        projectId: null,
        branchesLoading: false,
        branchStatus: "idle",
        branches: [],
        preferredBase: "",
        branchError: "",
        base: "",
        ...clearError(),
      });
    }

    const requestGeneration = ++branchRequestGeneration;
    const command = { type: "listBranches", projectId: selectedProjectId };
    const next = update({
      projectId: selectedProjectId,
      branchesLoading: true,
      branchStatus: "loading",
      branches: [],
      preferredBase: "",
      branchError: "",
      base: "",
      result: null,
      ...clearError(),
    });
    if (state.projectId === selectedProjectId &&
        state.branchesLoading &&
        state.branchStatus === "loading" &&
        branchRequestGeneration === requestGeneration) {
      emit(command);
    }
    return next;
  }

  function selectProject(projectId) {
    return loadBranches(projectId);
  }

  function loadProjects() {
    const next = update({ projectsLoading: true, ...clearError() });
    emit({ type: "listProjects" });
    return next;
  }

  function retryBranches() {
    return loadBranches(state.projectId);
  }

  function setBase(base) {
    return update({ base: stringValue(base), ...clearError() });
  }

  function setBranch(branch) {
    return update({ branch: stringValue(branch), ...clearError() });
  }

  function setAgent(agentId) {
    return update({ agentId: hasText(agentId) ? agentId : null, ...clearError() });
  }

  function worktreeValidationError() {
    if (!hasText(state.projectId)) return "Choose a repository.";
    if (state.branchStatus !== "loaded" || !state.branches.includes(state.base)) return "Choose a base branch.";
    if (!isValidBranchName(state.branch)) return "Enter a valid branch name.";
    return "";
  }

  function validationError() {
    const worktreeError = worktreeValidationError();
    if (worktreeError) return worktreeError;
    if (!hasText(state.agentId)) return "Choose an agent.";
    return "";
  }

  function startNewWorktree() {
    if (state.submitting || state.outcomeUnknown) return false;
    update({ mode: "new", step: "worktree", error: null, result: null });
    return true;
  }

  function next() {
    if (state.submitting || state.outcomeUnknown) return false;
    if (state.step === "agent") return true;

    const message = worktreeValidationError();
    if (message) {
      update({ error: { stage: "validation", message, worktreeId: null } });
      return false;
    }

    update({ mode: "new", step: "agent", error: null });
    return true;
  }

  function back() {
    if (state.submitting) return false;
    if (state.step === "agent") {
      update({ step: "worktree", error: null });
      return true;
    }
    if (state.mode === "new") {
      update({ mode: "existing", error: null });
      return true;
    }
    return false;
  }

  function submit() {
    if (state.submitting) return false;
    if (state.outcomeUnknown && !canRetry(state)) return false;

    const message = validationError();
    if (message) {
      update({ error: { stage: "validation", message, worktreeId: null }, result: null });
      return false;
    }

    const command = {
      type: "createWorktreeSession",
      projectId: state.projectId,
      base: state.base,
      branch: state.branch,
      agentId: state.agentId,
    };
    update({
      submitting: true,
      error: null,
      result: null,
      outcomeUnknown: false,
      recovery: { sessions: false, worktrees: false },
    });
    emit(command);
    return true;
  }

  function applyProjectList(projects) {
    const normalizedProjects = Array.isArray(projects)
      ? projects.filter((project) => project && hasText(project.id)).map(copyValue)
      : [];
    const currentProjectExists = normalizedProjects.some((project) => project.id === state.projectId);
    const selectedProjectId = currentProjectExists ? state.projectId : normalizedProjects[0]?.id || null;

    update({ projectsLoading: false, projects: normalizedProjects });
    if (selectedProjectId && selectedProjectId !== state.projectId) {
      loadBranches(selectedProjectId);
    } else if (!selectedProjectId && state.projectId) {
      loadBranches(null);
    }
  }

  function applyBranchList(message) {
    if (!hasText(message.projectId) || message.projectId !== state.projectId || !state.branchesLoading || state.branchStatus !== "loading") return false;

    const branches = Array.isArray(message.branches)
      ? message.branches.filter((branch) => hasText(branch))
      : [];
    const preferredBase = branches.includes(message.preferredBase) ? message.preferredBase : "";
    const base = preferredBase || (branches.includes(state.base) ? state.base : branches[0] || "");
    update({
      branchesLoading: false,
      branchStatus: "loaded",
      branches,
      preferredBase,
      branchError: "",
      base,
      ...clearError(),
    });
    return true;
  }

  function applyBranchListFailure(message) {
    if (!hasText(message.projectId) || message.projectId !== state.projectId || !state.branchesLoading || state.branchStatus !== "loading") return false;

    const branchError = stringValue(message.message);

    update({
      branchesLoading: false,
      branchStatus: "failed",
      branches: [],
      preferredBase: "",
      branchError,
      base: "",
      error: { stage: "branches", message: branchError, worktreeId: null },
    });
    return true;
  }

  function receive(message) {
    if (!message || typeof message.type !== "string") return false;

    switch (message.type) {
      case "projectList":
        applyProjectList(message.projects);
        return true;
      case "branchList":
        return applyBranchList(message);
      case "branchListFailed":
        return applyBranchListFailure(message);
      case "worktreeSessionCreated":
        if (!state.submitting || state.outcomeUnknown) return false;
        if (!isUsableSession(message.session)) return false;
        update({ submitting: false, error: null, result: copyValue(message.session) });
        return true;
      case "worktreeSessionCreationFailed":
        if (!state.submitting || state.outcomeUnknown) return false;
        if (!isCreationFailure(message)) return false;
        const isSessionFailure = message.stage === "session" && hasText(message.worktreeId);
        update({
          submitting: false,
          result: null,
          mode: isSessionFailure ? "existing" : state.mode,
          step: isSessionFailure || message.stage === "worktree" ? "worktree" : state.step,
          createdWorktreeId: isSessionFailure ? message.worktreeId : state.createdWorktreeId,
          selectedWorktreeId: isSessionFailure ? message.worktreeId : state.selectedWorktreeId,
          error: {
            stage: stringValue(message.stage),
            message: stringValue(message.message),
            worktreeId: hasText(message.worktreeId) ? message.worktreeId : null,
          },
        });
        return true;
      default:
        return false;
    }
  }

  function subscribe(subscriber) {
    if (typeof subscriber !== "function") return () => {};
    subscribers.add(subscriber);
    return () => subscribers.delete(subscriber);
  }

  function disconnect() {
    if (!state.submitting) return false;
    update({
      submitting: false,
      outcomeUnknown: true,
      recovery: { sessions: false, worktrees: false },
      error: { stage: "unknown", message: "Connection lost while creating the worktree.", worktreeId: null },
    });
    return true;
  }

  function markRecoveryListLoaded(list) {
    if (!state.outcomeUnknown || (list !== "sessions" && list !== "worktrees")) return false;
    update({ recovery: { ...state.recovery, [list]: true } });
    return true;
  }

  return {
    loadProjects,
    selectProject,
    retryBranches,
    setBase,
    setBranch,
    setAgent,
    startNewWorktree,
    next,
    back,
    canSubmit: () => canSubmit(state),
    canRetry: () => canRetry(state),
    submit,
    disconnect,
    markRecoveryListLoaded,
    receive,
    snapshot,
    subscribe,
  };
}

globalThis.RemoteWorktreeCreation = { createFlow, initialState, canSubmit, canRetry, isValidBranchName };
