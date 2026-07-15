# Cmd-P Search Filtering Reliability

## Problem

Cmd-P file filtering can appear to stop while a large candidate set is being
ranked. `SearchModel` is main-actor isolated, and its fallback fuzzy-scoring
and sorting work runs synchronously on that actor. While that work is running,
SwiftUI cannot deliver later query changes, so the active search cannot be
cancelled promptly.

Search completion also relies primarily on cooperative task cancellation.
A superseded task can still mutate shared presentation state on a delayed or
backend-specific completion path. In particular, every task unconditionally
clears `isLoading`, even when a newer search is active.

## Goals

- Keep the search field responsive while filtering large repositories.
- Ensure only the latest query can publish results, selection changes, errors,
  loading state, or idle completion.
- Preserve the current results while their replacement is loading.
- Show the app's custom inline spinner at the right edge of the search field.
- Cover rapid query changes and stale completion paths with regression tests.

## Non-Goals

- Changing fuzzy-match scoring or result caps.
- Streaming incremental file-name results.
- Redesigning the search dialog or content-search backend.
- Adding new loading components or visual styles.

## Design

### File Ranking

Move CPU-heavy file candidate scoring and sorting into a pure, sendable
operation that does not run on the main actor. `SearchModel` remains responsible
for capturing the query, scope, targets, backend results, and status data, then
awaits the ranking result before publishing it.

The operation retains the existing behavior:

- merge indexed backend rows with tracked entries omitted by the backend;
- apply the existing fuzzy score, filename bonus, and status bonus;
- sort empty-query results by status and path;
- sort filtered results by score; and
- cap the published list at 50 rows.

Cancellation checks remain in the worker so obsolete work can terminate early,
but correctness does not depend on cancellation alone.

### Search Generation Ownership

Each reschedule increments a generation and captures it in the scheduled task.
All model mutations produced by asynchronous search work must verify that the
captured generation is still current. This includes:

- final file results;
- partial and final content results;
- content-search error banners;
- selection clamping;
- `isLoading`; and
- idle-waiter completion.

The latest generation sets loading when its debounced work starts and clears it
when that same generation settles. A stale generation may return or be cancelled
without changing state owned by its successor. Closing the dialog invalidates
the current generation, cancels work, clears loading, and resumes any test idle
waiters.

Existing rows remain visible between rescheduling and publication. This avoids
an empty-state flash and makes the spinner the explicit indication that the
visible rows are being replaced.

### Loading Indicator

`SearchInputRow` observes `model.isLoading`. While true, it renders the existing
custom `Spinner` after the text field and before the clear button and mode tabs.
The spinner uses a fixed compact frame so its appearance does not shift the
tabs or resize the dialog. It has an accessibility label identifying search in
progress and is absent when the latest search is idle.

## Error Handling

The existing user-facing content and partial-repository error messages remain
unchanged. An error from a stale generation is discarded. An error from the
latest generation publishes normally and clears loading when that generation
settles.

## Testing

Add focused Swift Testing coverage that controls backend timing:

- a slow file search is superseded by a newer query, and only the newer query
  publishes;
- CPU-heavy file ranking does not prevent a later query from being scheduled;
- stale content partial/failure completion cannot overwrite newer results;
- an older task settling cannot clear loading owned by a newer task;
- the latest task settling clears loading and releases idle waiters; and
- closing during a search leaves loading false and no waiter stranded.

Run the focused search tests first, then the repository-required `xcodegen`,
build, and full test commands.
