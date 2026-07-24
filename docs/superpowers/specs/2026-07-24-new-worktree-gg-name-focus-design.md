# New Worktree GG Name Focus Design

## Problem

`NewWorktreeDialog` starts with an empty `projectId`. Its first render therefore
treats the name field as a regular branch field and binds the focused
`AlasField` to `branch`. The dialog selects its initial project in `.onAppear`.
When that project inherits GG mode, the same visible field switches to the
independent `stackName` binding. Keystrokes entered during this launch-time
transition can land in `branch` and then disappear when the field starts
displaying `stackName`.

The branch-name input filter does not treat any ordinary letter specially. A
leading `f` is commonly observed because it is often the first character typed
while the binding transition is still in progress.

## Desired Behavior

- The name field uses the correct branch or stack-name binding on its first
  render.
- Focus is established once, without discarding early input.
- Regular branch and GG stack-name drafts remain independent when the user
  manually toggles GG mode.
- Existing repository-switch behavior remains unchanged: selecting another
  repository resets GG mode to inherit and retains the separate drafts.

## Design

Resolve the dialog's initial project ID in its initializer and use that value to
initialize the `projectId` state before SwiftUI produces the first body. The
resolution order remains the same as the current `.onAppear` logic:

1. Use `presetProjectId` when it identifies an existing project.
2. Otherwise use the first available project.
3. Use an empty ID when there are no projects.

Keep the defensive `.onAppear` fallback for cases where the state is empty when
the view is first constructed or changes before presentation. With the normal
sheet flow, `.onAppear` will see an already-resolved project and will not change
the name field's binding.

No changes are needed in `AlasField`, the input filter, GG mode evaluation, or
the separate `branch` and `stackName` state.

## Alternatives Considered

### Delay the name field until `.onAppear`

This prevents input before project resolution, but introduces a visible
one-frame layout and focus transition.

### Use one intermediary name draft

This gives the editor a stable binding, but requires synchronization logic and
risks changing the existing behavior that preserves independent branch and
stack-name drafts.

## Testing

Add focused unit coverage for initial project-ID resolution:

- a valid preset wins over project order;
- a missing preset falls back to the first project;
- no preset uses the first project;
- no projects produces an empty ID.

Retain the existing tests proving that regular branch and GG stack names are
independent. Run the targeted test suite, regenerate the Xcode project, then run
the required macOS build and full tests.
