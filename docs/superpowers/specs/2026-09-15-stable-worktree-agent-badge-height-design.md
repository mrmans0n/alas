# Stable worktree agent badge height

## Problem

A worktree row is 49 points tall without an active agent badge and 52 points tall with one. Terminal agents can toggle this badge often, so neighboring sidebar entries move by 3 points on every status change.

`HarnessSessionBadge` has a fixed 21-point frame. The metadata `HStack` in `WorktreeRowView` reserves only 18 points, so the badge increases that line's height when it appears.

## Design

Change the metadata row's minimum height from 18 to 21 points. The row will remain 52 points tall whether an agent badge is absent, running, or waiting.

Keep the 21-point badge unchanged. Shrinking it would reduce padding around the 14-point agent logo. Overlaying it would add alignment and hit-testing complexity without improving the result.

## Verification

Use `WorktreeRowHeightTests.rowHeightIsStableWithAndWithoutBadge` as the regression check. It currently fails with measured heights of 49 and 52 points. After the change, both measurements must match. The existing running-versus-waiting test must continue to pass.

Build the app and exercise a terminal agent status change in the sidebar to confirm adjacent worktree entries no longer move.

## Scope

No changes to badge appearance, status signaling, worktree-row spacing outside this height reservation, or agent activation behavior.
