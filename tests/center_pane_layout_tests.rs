use std::fs;

fn compact(source: &str) -> String {
    source.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[test]
fn workspace_bounds_active_tab_body_below_fixed_tab_bar() {
    let source =
        fs::read_to_string("src/ui/workspace.rs").expect("workspace UI source is readable");
    let compact = compact(&source);

    assert!(compact.contains(".child(render_tab_bar("));
    assert!(
        compact.matches(".min_h(px(0.0))").count() >= 2,
        "workspace panel and active body wrapper must allow scrollable tab content to shrink"
    );
}

#[test]
fn central_file_and_image_bodies_are_scroll_owners() {
    let file_pane = compact(
        &fs::read_to_string("src/ui/file_pane.rs").expect("file pane UI source is readable"),
    );
    let image_view = compact(
        &fs::read_to_string("src/ui/image_view.rs").expect("image view UI source is readable"),
    );

    assert!(
        file_pane.contains(
            ".id(\"file-pane-content\") .flex() .flex_1() .size_full() .min_h(px(0.0)) .overflow_scroll()"
        ),
        "generic file pane content must be a bounded scroll container"
    );
    assert!(
        file_pane.contains(".font_family(TERMINAL_FONT_FAMILY)")
            && file_pane.contains(".text_size(px(TERMINAL_FONT_SIZE_PX))")
            && file_pane.contains(".line_height(px(CELL_HEIGHT_PX))"),
        "generic file pane content must use the same text metrics as terminal/source panes"
    );
    assert!(
        image_view.contains(
            ".id(\"image-body\") .flex() .flex_1() .min_h(px(0.0)) .items_center() .justify_center() .overflow_scroll()"
        ),
        "image body must be a bounded scroll container below the toolbar"
    );
}
