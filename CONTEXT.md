# Alas workspace context

Alas organizes repositories and their coordinated working copies while keeping navigation, execution, and attached work context distinct.

## Language

**Project**:
A persistent Alas entity for one Git repository on one execution location.
_Avoid_: Repository, workspace

**Space**:
An ordered sidebar visibility collection whose members are Projects or Workspaces.
_Avoid_: Workspace, project group

**Workspace**:
A persistent, ordered collection of Workspace Members used to create coordinated Workspace Checkouts.
_Avoid_: Space, multi-repository Project

**Workspace Member**:
An independently identified membership relationship that connects one Workspace to one Project. A Project appears at most once in a Workspace, and a missing Project does not erase the membership.
_Avoid_: Repository, checkout member

**Workspace Configuration**:
The checkout-scoped defaults owned by a Workspace and resolved after global settings for future Workspace Checkouts and shared sessions. It owns shared launch behavior and checkout-root MCP servers, never inherits shared behavior from a member Project, and changes only through an explicit Workspace edit.
_Avoid_: Project configuration, checkout configuration

**Workspace Member Configuration**:
The repository-scoped overrides owned by a Workspace Member and resolved after its Project settings for future Workspace Checkouts. It may adjust member setup, GG policy, and inherited Project MCP selection but cannot control shared session behavior.
_Avoid_: Workspace Configuration, Project configuration

**Workspace Checkout Configuration Snapshot**:
The resolved, immutable operational settings captured when a Workspace Checkout is created. It contains shared launch settings, member setup and GG policy, and qualified checkout-root and member-bound MCP configurations; repairs and new shared sessions use it rather than later global, Workspace, or Project settings, without refresh or silent substitution.
_Avoid_: Live settings, Workspace Configuration

**Creation Launch Preference**:
The resolved choice of whether checkout creation opens a shared session and, when it does, whether it opens Terminal or ACP with a selected agent and permission mode. Global settings provide the base while Projects and Workspaces may define scoped overrides.
_Avoid_: Default agent, launcher mode

**Shared Session Startup Script**:
The optional shell script resolved from global and Workspace settings and run at the Workspace Checkout root when a shared Terminal opens. It does not run before ACP sessions or compose member Project session-open scripts.
_Avoid_: Worktree creation script, Project startup script

**Workspace Checkout**:
A persistent, independently identified snapshot of a Workspace and all its current members, created as coordinated worktrees under one common directory. It is the stable owner of shared Terminal and ACP sessions; later Workspace changes and repository focus changes do not change the snapshot, its resolved root, or a running session's scope.
_Avoid_: Worktree, session

**Repository Focus**:
The available Workspace Checkout member whose repository-specific Files, Changes, and Review panes are active. It does not own or retarget the Workspace Checkout's shared Terminal and ACP sessions.
_Avoid_: Session scope, selected Workspace Checkout

**Repository Target**:
The Workspace Checkout member that a repository-specific operation resolves from its working directory or receives explicitly. Repository Focus never implicitly supplies the target.
_Avoid_: Repository Focus, active repository

**Checkout Boundary**:
The physical subtree rooted at a Workspace Checkout's authoritative root within which its Alas-managed file operations may act. It includes member worktrees and shared-root files, but does not make Terminal processes a filesystem sandbox.
_Avoid_: Member boundary, execution location

**Session Owner**:
The Worktree or Workspace Checkout whose stable identity partitions Terminal tabs, ACP sessions, attachments, and restoration state. Repository Focus and filesystem paths do not change that ownership.
_Avoid_: Repository Focus, working directory

**Checkout Manifest**:
A concise, Alas-managed description of one Workspace Checkout and its ordered member snapshot, stored under the common root for checkout-scoped tools. It records stable identities, exact member paths, and current availability; it is not user configuration.
_Avoid_: Workspace configuration, project manifest

**Incomplete**:
The state of a Workspace whose member cannot resolve to a Project, or a Workspace Checkout whose expected member worktree is missing or conflicts with its recorded identity.
_Avoid_: Broken, orphaned

**Needs Attention**:
The state of a Workspace Checkout member whose expected worktree identity is present but a recoverable setup or cleanup operation has failed.
_Avoid_: Incomplete, failed checkout

**Archived**:
The state of a Workspace Checkout removed from active navigation with no live Terminal or ACP processes, while its member worktrees and persisted session history remain intact.
_Avoid_: Deleted, suspended

**Explicitly Deleted**:
The unavailable state of a Workspace Checkout member whose worktree the user deliberately removed. The member remains in the checkout snapshot and may be recreated from its frozen plan.
_Avoid_: Removed member, forgotten member

**Former Workspace**:
A read-only navigation container for surviving Workspace Checkouts whose source Workspace has been deleted. It retains the source Workspace identity and fallback name but cannot create new checkouts.
_Avoid_: Orphaned Workspace, deleted Workspace

**Execution Location**:
The local machine or one exact normalized SSH destination on which every member of a Workspace or Workspace Checkout executes.
_Avoid_: Host, environment

**Work Item**:
The single current provider-neutral external context attached to one Workspace Checkout. It retains a context snapshot and may identify the Workspace Checkout Member whose repository hosts it through an exact repository identity match; sources without a matching member remain external. The attachment may be explicitly added, replaced, refreshed, edited when supported, or detached. Refresh preserves source identity and the previous usable snapshot on failure. The Work Item remains readable when its hosting member is unavailable. It supplies shared session context but never becomes an implicit Repository Target, owns a member's pull requests or reviews, or determines checkout lifecycle.
_Avoid_: Issue

**Member Review**:
The review state owned by one Workspace Checkout Member and its Project. It may contain one ordinary provider review request or the Project's ordered GG stack. Its actions and completion never transfer to the Workspace Checkout or Work Item.
_Avoid_: Workspace review, shared review

**Member Review Rollup**:
A read-only Workspace Checkout summary that preserves snapshot member order and visibility while reporting each member's availability, publication state, and Member Review state. It provides no combined completion state; every action targets one member and review.
_Avoid_: Workspace review, checkout completion
