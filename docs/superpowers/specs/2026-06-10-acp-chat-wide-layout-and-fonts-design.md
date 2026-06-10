# ACP Chat Wide Layout and Fonts Design

## Summary

Improve the central ACP chat pane on wide monitors without changing the current
small-screen experience. The transcript and composer should reclaim some unused
horizontal space, but remain bounded so prose stays readable. Add chat-specific
font family and font size settings under Settings > Agents > Chat, matching the
terminal and editor preference model.

## Goals

- Keep existing small and medium pane behavior visually unchanged.
- Expand the ACP transcript and composer on wide panes from the current `720 pt`
  reading column to a `960 pt` maximum.
- Keep the inline plan sidebar independent from the chat column width.
- Let users configure ACP chat font family and base font size from
  Settings > Agents > Chat.
- Apply chat typography consistently across ACP prose, user messages, queued
  previews, tables, quotes, headings, fenced code blocks, and composer input.

## Non-Goals

- No user-facing chat width setting in this pass.
- No changes to terminal or code editor font settings.
- No redesign of ACP message row styling, composer controls, or plan sidebar
  visibility rules.
- No change to mobile/remote chat surfaces.

## Layout

The current ACP chat content is capped at `720 pt` in both `ACPMessageList` and
`ACPComposer`. Replace those independent constants with a shared pure layout
calculation.

The calculation should:

- Return `720 pt` for panes that cannot comfortably fit more.
- Grow only after the center pane is clearly wide enough.
- Cap at `960 pt`.
- Preserve existing horizontal padding and gutter behavior.
- Be easy to unit test without SwiftUI rendering.

The resulting max width is applied to:

- The transcript content stack in `ACPMessageList`.
- The composer pill in `ACPComposer`.
- Any ACP row whose internal width currently assumes the old `720 pt` column
  and would otherwise look inconsistent inside the wider column.

User message bubbles should still be constrained within the chat column rather
than stretching to the full pane. Code blocks and tables may use the wider
column, because horizontal content benefits from the extra room.

The existing `ACPPlanSidebar` remains a separate `320 pt` column controlled by
`ACPPlanSidebarVisibility`. The chat width calculation should use the width
available to the chat side after the sidebar is laid out by the existing
`HStack`, not try to account for the sidebar itself.

## Chat Typography Settings

Add chat appearance fields to `AppConfig.Agents`, because the UI location is
Settings > Agents > Chat and these settings are specific to ACP chat rather
than terminal harness behavior:

- `chatFontFamily: String`, default `"JetBrainsMono Nerd Font"`.
- `chatFontSize: Int`, default `13`, clamped to `[8, 64]` during decode and
  writes.

Settings > Agents > Chat should add:

- `Font family`, using the existing `FontFamilyPicker` and
  `MonospaceFontCatalog.families()`.
- `Font size`, using the same numeric `AlasField` pattern as Terminal and Code.

ACP views should receive a small value object, for example `ACPChatTypography`,
with the resolved family and base size. It should expose derived sizes for:

- paragraph text
- headings
- quotes
- table cells and headers
- fenced code
- small labels such as code block headers and copy controls where appropriate

This keeps current relative sizing intact while making the base preference
effective. The initial mapping should preserve the current defaults when
`chatFontSize == 13`.

## Data Flow

`ACPSessionView` reads `state.config.agents.chatFontFamily` and
`state.config.agents.chatFontSize`, builds the typography value, and passes it
to the transcript and composer subtree.

`ACPMarkdownText` should accept typography explicitly rather than reading
`AppState`, so it remains reusable and testable. Call sites in:

- `ACPMessageList`
- `ACPQueuedBubble`
- `ACPMarkdownText.CodeBlockView`

should thread the same typography value through nested markdown/code views.

The composer input field should use the same base chat font. If the AppKit field
needs an additional initializer or binding for font injection, that plumbing is
part of this change.

## Compatibility

Older config files that lack the new agent fields must decode with defaults.
Encoding should include the new fields once saved.

The new width logic should not move small panes, because existing users already
have a good layout there. The cap should prevent very wide line lengths on
ultrawide displays.

## Testing

Add Swift Testing coverage for:

- `AppConfig` default chat font values.
- Backward-compatible decode when `agents` lacks chat font fields.
- Font size clamping on decode.
- The pure ACP chat width calculation at narrow, current, wide, and ultrawide
  pane widths.

Run the standard verification before finishing implementation:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Open Decisions

None. The approved layout direction is the moderate adaptive cap: grow from
`720 pt` to a `960 pt` maximum, without adding a separate width setting.
