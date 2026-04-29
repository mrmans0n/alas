use gpui::{App, KeyBinding, Menu, MenuItem, SystemMenuType, actions};

actions!(alas, [Quit]);

pub fn setup_lifecycle(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("ctrl-q", Quit, None),
    ]);
    cx.set_menus(vec![Menu {
        name: "Alas".into(),
        items: vec![
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::action("Quit", Quit),
        ],
    }]);
    cx.on_window_closed(|cx| {
        if cx.windows().is_empty() {
            cx.quit();
        }
    })
    .detach();
}
