# Chat Proportional Fonts Design

## Context

Commit `d025aa6` added chat typography settings and wired chat rendering to a shared font-family setting. The setting currently uses `MonospaceFontCatalog`, so only fixed-pitch families are selectable. Before that change, ACP chat prose and the composer used the macOS system font through `.system(...)` / `NSFont.systemFont(...)`; code blocks and code-like surfaces stayed monospaced.

## Goals

- Let Chat settings choose proportional as well as monospaced font families.
- Restore the default chat prose/composer font to the previous macOS system font.
- Keep code blocks, syntax-highlighted snippets, inline diffs, terminal output, and editor/code settings on their existing monospace/code-font behavior.
- Preserve existing persisted user choices.

## Design

Add a chat-specific font catalog that returns all installed font families, sorted case-insensitively. Reuse the existing `FontFamilyPicker`, but let callers provide neutral empty-state copy so Chat can say "No fonts found" while Terminal/Code can keep monospace wording.

Represent the old default as an empty `chatFontFamily`, meaning "System". This avoids depending on a private or version-specific family name and matches SwiftUI/AppKit's previous semantic `.system` behavior. The picker trigger should render this as "System" and rows should include a selectable "System" option before installed families.

Add a general font resolver for chat typography. For non-empty families, it should resolve the regular face from available family members using the same family-name approach as code fonts. If resolution fails, fall back to `NSFont.systemFont(ofSize:)`. `ACPChatTypography` should use this general resolver for prose, headings, quotes, the composer, and placeholders. Existing code block rendering should continue using `CenterTypography.resolveCodeFont`.

Persisted configs that omit `agents.chatFontFamily` should decode to the empty semantic default. Configs that already store a specific family, including the current `"JetBrainsMono Nerd Font"` value, should keep that value.

## Testing

- Update config default and legacy decode tests to expect an empty chat font family.
- Add typography resolver coverage for the semantic system default and missing-family fallback.
- Add settings picker/catalog coverage where practical without depending on host-specific installed fonts.

## Out Of Scope

- Migrating existing user configs that explicitly contain `"JetBrainsMono Nerd Font"`.
- Changing code/terminal font settings.
- Adding per-region chat font settings.
