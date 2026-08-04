# Finder-Style File Actions

## Goal

Add consistent macOS file-opening actions to changed-file and Files-tab context menus. Files can be opened inside Alas, with their default system application, or with another compatible application. The Files tab also gains the general navigation and path actions that are useful outside the Changes workflow.

## Scope

This change covers file rows in the Working Tree section and file and directory rows in the Files tab. It does not add Git mutation actions to the Files tab. Staging, unstaging, discarding, ignoring, and copying diffs remain part of the Changes workflow.

## Menu Behavior

### Working Tree files

The existing context menu will contain:

1. Open in Alas
2. Open
3. Open With
4. View at HEAD
5. Compare with HEAD
6. File History
7. Copy Relative Path
8. Copy Full Path
9. Reveal in Finder
10. Existing diff, staging, discard, and ignore actions

`Open in Alas` is the existing editor or preview action. `Open` asks macOS to use the default handler. `Open With` lists the compatible applications reported by Launch Services.

### Files-tab files

File rows will contain:

1. Open in Alas
2. Open
3. Open With
4. File History
5. Copy Relative Path
6. Copy Full Path
7. Reveal in Finder

The normal primary click remains unchanged and opens the file in Alas.

### Files-tab directories

Directory rows will contain:

1. Open
2. Copy Relative Path
3. Copy Full Path
4. Reveal in Finder

`Open` uses the system default for a directory, normally Finder. Directories do not offer Open in Alas, Open With, or File History. The normal primary click continues to expand or collapse the row.

## Architecture

Extend `FileSystemOpen` with compatible-application discovery and opening a URL with a selected application. A small application value will carry the application bundle URL, display name, icon, and whether it is the default handler.

Application discovery will use macOS Launch Services through `NSWorkspace`. Results will be deduplicated by standardized application URL. The default handler will be listed first and identified as the default; remaining applications will be sorted by localized display name.

A reusable SwiftUI context-menu section will render the common general actions. Optional callbacks control whether Open in Alas, File History, path copying, and Finder reveal are present. Supplying a local URL enables Open and Open With. Working Tree composes its Git-specific actions around this shared section, while Files-tab rows use the general section directly.

The right-pane parents remain responsible for resolving a worktree-relative path into a local file URL and for providing Alas-native callbacks. This keeps path and worktree knowledge out of the reusable menu.

## Local, Remote, and Missing Targets

System Open, Open With, and Reveal in Finder are available only for local worktrees. Remote worktrees keep Open in Alas, File History, Copy Relative Path, and Copy Full Path, but omit local-system actions.

An on-disk existence check controls system opening. Deleted or otherwise missing Working Tree paths cannot be opened by macOS, but revision-based actions such as View at HEAD and File History remain available. Files-tab nodes normally exist by construction; the same guard protects against filesystem races.

If Launch Services finds no compatible applications, Open With contains one disabled `No Compatible Applications` item. Application launch failures continue to use the existing `NSWorkspace` behavior; this feature does not introduce a separate alert system.

## Testing

Unit tests will cover the pure policy and ordering logic:

- application URL deduplication;
- default application ordering and marking;
- localized name ordering for non-default applications;
- availability for local files and directories;
- omission of system actions for remote paths;
- omission of system opening for missing targets; and
- differences between file and directory action sets.

Implementation verification will run the project-required commands:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
