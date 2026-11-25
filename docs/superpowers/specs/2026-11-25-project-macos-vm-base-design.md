# Project macOS VM base

## Goal

Let a local Git project prepare a macOS VM once, in a real guest desktop, and use that disk for new worktree VMs. The user can install tools, configure the guest, and verify the setup before publishing it. They do not need to create a worktree. Editing a draft never changes what new worktrees receive until the user saves it as the project base.

This is a local Alas setting for supported Macs. It does not change Linux VMs, remote projects, folder projects, or `.alas` repository configuration. The shared macOS base and automatic script cache keep their current roles for projects without a saved base.

## Project settings and setup window

Add **Customize macOS base…** to Project Settings → Worktree VMs. Show whether new macOS VMs use a saved project base or the default, the save date if present, and whether there is a draft. Compare the selected base's provenance with the current shared image and effective guest setup script. A different shared build, a new seal of the same build, or a changed script is a status message, not an instruction to switch sources. If the shared base is unavailable, say so without marking the saved base unusable. Explain that a saved base replaces script execution for new macOS VMs and for **Reset from scratch**; the script setting still applies to Linux and to the default macOS path.

Customize opens a dedicated setup VM window for the project. If the window is already open, focus it. Use this source order:

1. Resume the project's existing draft, if any.
2. Otherwise clone the saved project base, if any. Inherit its provenance and do not run the script again.
3. Otherwise clone the sealed shared macOS base and run the project's effective guest setup script, if nonblank. Use the existing shared setup flow if this step needs a shared image and none is ready. When setup completes, continue in the same project window. Do not open or invent a worktree for this flow.

The draft has its own VM identity and consumes a slot from the same limit as other VMs. Reuse the guest display, slot admission, and cross-process VM ownership; do not boot the same draft in two processes. Closing the window or relaunching Alas leaves the draft available to reopen. Give it a draft-specific transfer folder, but no worktree mount or worktree tool routing. Warn that anything copied onto the guest disk, including credentials, can reach every future clone. The host transfer folder itself is not part of the base.

Releasing a draft's slot or quitting Alas shuts the guest down rather than suspending it. If Alas cannot confirm shutdown, it leaves the slot occupied or cancels quit instead of forcing the guest off.

For a draft created from the shared base, capture the effective guest setup script from saved Project Settings and any repo script default at creation. Persist the selected script locally for interrupted setup and retries; record its hash in provenance and never publish the script payload as base metadata. If a script was captured, wait for the guest helper and use the existing bounded script execution. The captured script must succeed before the draft can be saved. A failure keeps the draft and any previous base. Show the failure and offer **Retry** with the captured script on the same disk, or **Discard draft**. Warn that retry does not undo changes from the failed run. A stop or interruption is not success, and reopening cannot silently clear a recorded failure. An edit to the script settings does not rewrite an existing draft; rebuilding from shared captures the new settings.

If Retry needs a VM slot, keep the retry request while the user chooses which VM to stop. Run the captured script after the draft starts, without asking the user to retry again.

## Save, discard, rebuild, and remove

**Save as project base** asks macOS to shut down cleanly. A timeout, forced stop, guest failure, or missing evidence for the draft's current boot generation does not qualify. If no valid evidence survives a relaunch, start the draft and shut it down cleanly before saving. Prevent any new draft boot or competing draft operation between shutdown confirmation and publication. A save failure leaves the draft and the prior saved base intact and reports what failed. A successful save consumes the draft; show the newly saved base and date.

**Discard draft** confirms and removes only the draft. **Rebuild from shared base** uses the current sealed shared image and effective script, even when there is a saved project base. Confirm before replacing a draft. If shared setup is canceled or the replacement cannot be cloned, keep the existing draft. Once the replacement draft is ready to boot, it takes the old draft's place and follows the same script and save rules. The old saved base stays active throughout.

**Remove project base** confirms that future macOS VMs will use the default again. Require the user to save or discard any outstanding draft first, including one whose window is closed. Removing a base does not delete or modify already-cloned VMs. Storage settings must not bypass the draft check or confirmation.

## Storage and publication

Key this storage by the same stable project ID used by the VM manager to identify a worktree's project. Do not depend on whether that project has a guest setup script. Keep one current draft and at most one active saved generation per project in a directory separate from the disposable `VMTemplate` cache. A saved generation is immutable and self-contained. It contains APFS clones of the clean disk and auxiliary storage, the hardware model, and metadata with its save date, originating shared build and seal, and the script hash or absence of a script. It contains no suspended memory, host transfer folder, or draft machine identity. Every bootable clone gets a fresh machine ID and MAC address, whether it is a setup draft or a worktree VM. Booting an existing draft again keeps that draft's identity.

Stage and validate the complete generation before making it active. Use one atomically replaced project state record to select the active generation and clear the consumed draft reference at the same commit point. An interrupted save before that point leaves the previous generation and draft selected. An interruption after it leaves the new generation selected and no unsaved draft, even if the old files are still on disk. Deletion after publication is cleanup, not part of deciding whether the save succeeded. Recovery must distinguish unpublished staging data and retired bundles from live drafts and saved bases.

The VM storage scan also reclaims unselected staging files for projects that were never opened again. Missing state means no bundle was selected. Unreadable state or a VM registry reference prevents automatic deletion.

Use a cross-process lock for project state changes, source selection through cloning, and generation cleanup. A clone racing a save sees the old complete generation or the new complete generation. A clone racing removal either uses the old generation while it is still pinned or resolves the default afterward. Use the existing VM registry ownership rules for draft boot and shutdown; order project storage and registry locks consistently. Cloning the shared base into a draft must also respect the existing guard against concurrent shared image customization or deletion.

Saved bases have no runtime dependency on the shared image. Shared image replacement, customization, deletion, and script edits must not invalidate them. Provenance describes their origin; it does not make them dependent clones in shared image deletion checks. Automatic template pruning must never remove a saved base or live draft, even if its project no longer exists. Settings → Worktree VMs lists saved project bases and drafts, with allocated size and owner when known. List entries whose project is gone as orphans for explicit cleanup. Cleanup must check ownership and use the same locking, so it cannot remove a running draft or files a clone is reading.

## Worktree VM creation

Use one macOS source decision for eager creation, the VM tab, agent-triggered creation, and reset. Existing worktree VM records win over source selection during ordinary creation. When a clone is needed, use these rules:

| Path | Saved project base exists | No saved project base |
| --- | --- | --- |
| New macOS VM, eager or on demand | Clone project base | Use a matching automatic template if available; otherwise clone the shared base and keep existing first-boot setup |
| Reset from scratch | Clone project base | Clone the shared base, bypass the automatic template, and keep existing first-boot setup |

A project-base clone does not run the current project script or publish a disposable script template. It has an initial clean point before first boot, so **Reset to clean point** returns to that VM's starting disk even if the project base later changes or is removed. Saving, rebuilding, and removing bases leave existing VMs and their clean points unchanged. If an explicitly saved base cannot be read or cloned, report the error rather than silently substituting the shared image or cache. For reset, secure the replacement source and clone before discarding the existing VM; it must not be lost because a concurrent remove invalidated the source after preflight.

`WorktreeVMManager` owns the source decision and clone lifecycle. The project source exposes status and a locked clone operation instead of handing callers a bundle path that can disappear. `VMBundle` supplies the APFS clone operations and fresh identity for bootable copies. `AppState` resolves project ID separately from script hash, and creation entry points use source readiness instead of requiring the shared image. The setup window reuses the guest-helper and script-running behavior behind `VMFirstBootSetup`, but does not invoke worktree clean-point or automatic template publication for a draft.

## Verification

- Focused Swift Testing coverage for creation and reset precedence, including a saved base without a shared image or script, bypass of the automatic template on reset, and an unreadable saved base. Verify a project-base clone has a clean point and no pending script.
- Exercise publication with an interrupted or failed save on both sides of the state switch, and a clone racing publication. Check that pruning leaves user-owned bases and drafts alone, including orphaned project entries, while retaining the existing automatic cache rules.
- Use two local projects. In one, customize before opening a worktree, close and reopen the draft, then save a visible guest change. Check eager or on-demand creation and **Reset from scratch** in that project, compare with the other project's default path, and confirm an existing VM and clean point are unchanged. Exercise a failed script and retry, a failed save, rebuild, discard, and removal; check that new clones keep using the previous base until a successful save.
- Check Screen Recording and Accessibility in a fresh clone with the actual signed app. The user approves any required grants in macOS. Record what the clone does, without promising that grants persist across cloning or signing changes. Do not edit the guest privacy database.
