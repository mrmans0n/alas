# Source-preserving display projection

## Scope and decision

Revise Task 14 of the code-editor LSP plan following the approved source/display boundary. The existing virtual-control-glyph probe failed native geometry. Evaluate a separate display document before integrating default-on inlay hints. This design does not assume TextKit 2 is required or that display attachments automatically solve input behavior.

## Ownership

`EditorBuffer.storage` remains authoritative source text. LSP positions, transactions, undo, diagnostics, find matches, persisted selections, and serialization remain source-based UTF-16 coordinates. A presentation adapter owns a separate attributed display storage containing copied source runs and virtual hint runs. Attachments may occur only in that display storage.

Each immutable projection records a source revision and hint generation. A sorted run map translates source boundaries to display boundaries and display selections back to source. Multiple hints at a boundary keep stable server order. Boundary affinity explicitly distinguishes positions before and after the hint group. Hint hit testing returns a hint identity, never a fabricated source character. Mapping rejects ranges that split Unicode scalars or exceed the captured revision.

## Input and editing

Native TextKit selection remains display-based inside the adapter. Source selection APIs must be explicitly named rather than overriding native properties to sometimes return source positions. An edit maps its display range to source, executes a buffer transaction, and rebuilds the projection from the confirmed source revision. A range spanning hints edits source characters only; a hint-only selection cannot delete source accidentally. Ordinary left/right movement skips virtual runs. Copy and cut serialize mapped source selections; cut uses the same source edit path.

IME marked text requires a deliberate composition bridge: source replacement and selection remain valid throughout composition, and incoming hint refreshes are deferred until composition ends. Cancelling composition restores the appropriate source state. Native undo must never record projection reconstruction or attachment removal; buffer undo remains the owner. Rebuilding hints must preserve source selection and scroll anchor and create no edit or undo entry.

## Geometry and consumers

Use actual distinct display positions for hint attachments, allowing native layout to account for widths, wrapping, and bidi order. Convert source ranges to display segments, excluding hint runs where source-only highlighting is intended. Caret anchors, diagnostics, find, semantic coloring, warning markers, minimap, and accessibility consume the same mapping. Accessibility source value and editable selections exclude virtual text; hint descriptions/actions are supplementary. RTL and wrapped-line correctness must be measured, not inferred from ASCII results.

## Feasibility gate

An isolated prototype must demonstrate distinct widths at one offset, tabs, wrapping, RTL, emoji, source-range rectangles, source caret/hit mapping, selection/copy, source edits, undo, and marked-text composition across a pending hint refresh. Use the original failing fixtures plus realistic NSTextView editing calls. Record unsupported or untested paths explicitly. Passing pure map tests is insufficient; native interaction must be exercised.

Only after the prototype passes will the production integration plan be expanded to enumerate every existing native-coordinate consumer. Existing Task 14 settings, client scheduling, resolution/actions, and Task 15 verification remain required. If the projection fails, retain evidence and revise the design before production integration.
