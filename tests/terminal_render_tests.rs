use alas::terminal::{
    TerminalCell, TerminalCellStyle, TerminalColor, TerminalGridSnapshot, TerminalRow,
    TerminalScreenMode, TerminalSize, TerminalStatus, TerminalViewport,
};

#[test]
fn plain_lines_are_derived_from_cells() {
    let snapshot = TerminalGridSnapshot {
        size: TerminalSize { cols: 4, rows: 2 },
        rows: vec![
            TerminalRow {
                cells: vec![TerminalCell::new("a"), TerminalCell::new("b")],
            },
            TerminalRow {
                cells: vec![TerminalCell::new("c"), TerminalCell::new("d")],
            },
        ],
        cursor: None,
        status: TerminalStatus::Running,
        viewport: TerminalViewport::visible(2),
        scrollback_rows: 0,
        screen_mode: TerminalScreenMode::Main,
    };

    assert_eq!(
        snapshot.plain_lines(),
        vec!["ab".to_string(), "cd".to_string()]
    );
    assert!(!snapshot.exited());
    assert_eq!(snapshot.exit_status(), None);
}

#[test]
fn snapshot_tracks_viewport_and_screen_mode() {
    let snapshot = TerminalGridSnapshot {
        size: TerminalSize { cols: 80, rows: 24 },
        rows: Vec::new(),
        cursor: None,
        status: TerminalStatus::Exited(Some(7)),
        viewport: TerminalViewport {
            scroll_offset_rows: 12,
            visible_rows: 24,
        },
        scrollback_rows: 120,
        screen_mode: TerminalScreenMode::Alternate,
    };

    assert_eq!(snapshot.viewport.scroll_offset_rows, 12);
    assert_eq!(snapshot.viewport.visible_rows, 24);
    assert_eq!(snapshot.scrollback_rows, 120);
    assert_eq!(snapshot.screen_mode, TerminalScreenMode::Alternate);
    assert!(snapshot.exited());
    assert_eq!(snapshot.exit_status(), Some(7));
}

#[test]
fn cell_style_tracks_color_and_attributes() {
    let style = TerminalCellStyle {
        foreground: Some(TerminalColor::rgb(255, 128, 0)),
        background: Some(TerminalColor::rgb(0, 16, 32)),
        bold: true,
        italic: true,
        underline: true,
        inverse: true,
        strikethrough: true,
    };
    let cell = TerminalCell {
        text: "λ".to_string(),
        style: style.clone(),
    };

    assert_eq!(cell.text, "λ");
    assert_eq!(cell.style, style);
    assert_eq!(
        cell.style.foreground,
        Some(TerminalColor {
            r: 255,
            g: 128,
            b: 0
        })
    );
    assert_eq!(
        cell.style.background,
        Some(TerminalColor { r: 0, g: 16, b: 32 })
    );
    assert!(cell.style.bold);
    assert!(cell.style.italic);
    assert!(cell.style.underline);
    assert!(cell.style.inverse);
    assert!(cell.style.strikethrough);
}
