use gpui::{App, Application, Context, IntoElement, Render, WindowOptions, div, prelude::*};

pub struct AlasShell;

impl Render for AlasShell {
    fn render(&mut self, _window: &mut gpui::Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div().flex().size_full().child("Alas")
    }
}

pub fn run() -> anyhow::Result<()> {
    Application::new().run(|cx: &mut App| {
        cx.open_window(WindowOptions::default(), |_, cx| cx.new(|_| AlasShell))
            .expect("failed to open Alas window");
    });

    Ok(())
}
