# Editor Line Number Gutter Design

## Goal

Add an optional line-number gutter to editable code editor panes. The setting is enabled by default and applies consistently anywhere `CodeEditorView` is used: normal file tabs, markdown editor and split modes, and external-file editor tabs.

The gutter must not interfere with text selection, editing, or drag behavior.

## Placement

Add the setting to `Settings -> Code -> Appearance` as `Show line numbers`. This is a better fit than the app-wide Appearance pane because the option is editor-specific and belongs next to font family, font size, and format-on-save.

Persist the preference as `AppConfig.Code.showLineNumbers`, defaulting to `true`. Existing configs that do not contain the field decode as `true`.

## Architecture

Use an AppKit `NSRulerView` subclass attached to the `NSScrollView` that contains `CodeTextView`.

The ruler is outside the editor document view, so line numbers are not part of the `NSTextView` content and cannot be selected. This also avoids changing the text storage, syntax highlighting, LSP offsets, or editor selection behavior.

`CodeEditorView` passes the persisted `showLineNumbers` value into the representable so SwiftUI triggers `updateNSView` when the setting changes. The view configures the scroll view's vertical ruler:

- when enabled, attach or update a `CodeEditorLineNumberRulerView`;
- when disabled, clear the vertical ruler and turn off `hasVerticalRuler` so no blank gutter remains.

## Rendering Behavior

The ruler draws only visible line numbers using the text view's layout manager, text container, visible rect, and document visible rect. It uses the current editor font for vertical alignment and a faint theme foreground color for the number text.

The gutter width adapts to the total line count digit width with a sensible minimum, so small files do not waste much space and large files do not clip numbers.

The ruler redraws when:

- the editor scrolls;
- text changes;
- the font changes;
- the theme changes;
- the setting is toggled.

Line numbers are right-aligned in the gutter and track wrapped or unwrapped TextKit line geometry according to the editor's existing layout. The first visual row for a logical line displays the line number; continuation fragments do not need their own repeated number.

## Scope

In scope:

- editable code editor tabs;
- markdown source editor mode and split-mode source editor;
- external-file editor tabs;
- persisted setting and migration default;
- focused tests for config decoding/defaults, plus line-number helper tests if the implementation extracts helper logic from the ruler view.

Out of scope:

- diff pane gutter changes;
- per-language or per-file overrides;
- relative line numbers;
- selecting or copying gutter numbers.

## Testing

Add or update Swift Testing coverage for:

- `AppConfig.defaults.code.showLineNumbers == true`;
- legacy code config JSON without `showLineNumbers` decodes as `true`;
- round-trip persistence preserves explicit `false`;
- extracted line-number width or visible-line helper logic, if such helpers are introduced.

Manual verification should cover:

- the gutter appears by default in editable files;
- toggling `Settings -> Code -> Appearance -> Show line numbers` updates open editors;
- drag selection starting in the text area behaves as before;
- the gutter does not select or copy line numbers;
- markdown split mode and external editor tabs follow the same setting.
