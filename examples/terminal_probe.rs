use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, IntoElement, KeyDownEvent,
    MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, Render, ScrollDelta, Window,
    WindowOptions, canvas, div, fill, point, prelude::*, px, rgb, size,
};
use std::time::Duration;

struct TerminalProbe {
    focus: FocusHandle,
    last_key: String,
    scroll_events: usize,
    last_scroll: String,
    right_clicks: usize,
    mouse_downs: usize,
    mouse_ups: usize,
    mouse_moves: usize,
    captured_drag_moves: usize,
    last_mouse: String,
    copied: usize,
    ticks: usize,
}

impl TerminalProbe {
    fn new(cx: &mut Context<Self>) -> Self {
        let probe = Self {
            focus: cx.focus_handle(),
            last_key: "none".to_string(),
            scroll_events: 0,
            last_scroll: "none".to_string(),
            right_clicks: 0,
            mouse_downs: 0,
            mouse_ups: 0,
            mouse_moves: 0,
            captured_drag_moves: 0,
            last_mouse: "none".to_string(),
            copied: 0,
            ticks: 0,
        };

        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(16))
                    .await;
                if this
                    .update(cx, |probe, cx| {
                        probe.ticks += 1;
                        cx.notify();
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();

        probe
    }
}

impl Render for TerminalProbe {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let on_key = cx.listener(
            |probe, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>| {
                let key = &event.keystroke.key;
                probe.last_key = format!(
                    "key={key:?} char={:?} mods={:?} held={}",
                    event.keystroke.key_char, event.keystroke.modifiers, event.is_held
                );

                // Concrete clipboard path for terminal copy: platform secondary modifier + C.
                if event.keystroke.modifiers.secondary() && key.eq_ignore_ascii_case("c") {
                    probe.copied += 1;
                    cx.write_to_clipboard(ClipboardItem::new_string(format!(
                        "terminal_probe_copy_{}",
                        probe.copied
                    )));
                }

                cx.notify();
            },
        );

        let on_scroll = cx.listener(
            |probe,
             event: &gpui::ScrollWheelEvent,
             _window: &mut Window,
             cx: &mut Context<Self>| {
                probe.scroll_events += 1;
                let pixels = event.delta.pixel_delta(px(16.0));
                probe.last_scroll = match event.delta {
                    ScrollDelta::Pixels(delta) => format!(
                        "pixels=({:.1},{:.1}) at=({:.1},{:.1}) phase={:?}",
                        delta.x.to_f64(),
                        delta.y.to_f64(),
                        event.position.x.to_f64(),
                        event.position.y.to_f64(),
                        event.touch_phase
                    ),
                    ScrollDelta::Lines(delta) => format!(
                        "lines=({:.1},{:.1}) pixels=({:.1},{:.1}) at=({:.1},{:.1}) phase={:?}",
                        delta.x,
                        delta.y,
                        pixels.x.to_f64(),
                        pixels.y.to_f64(),
                        event.position.x.to_f64(),
                        event.position.y.to_f64(),
                        event.touch_phase
                    ),
                };
                cx.notify();
            },
        );

        let on_mouse_down = cx.listener(
            |probe, event: &MouseDownEvent, _window: &mut Window, cx: &mut Context<Self>| {
                probe.mouse_downs += 1;
                if event.button == MouseButton::Right {
                    probe.right_clicks += 1;
                }
                probe.last_mouse = format!(
                    "down={:?} at=({:.1},{:.1}) clicks={} first_mouse={} mods={:?}",
                    event.button,
                    event.position.x.to_f64(),
                    event.position.y.to_f64(),
                    event.click_count,
                    event.first_mouse,
                    event.modifiers
                );
                cx.notify();
            },
        );

        let on_mouse_move = cx.listener(
            |probe, event: &MouseMoveEvent, _window: &mut Window, cx: &mut Context<Self>| {
                probe.mouse_moves += 1;
                probe.last_mouse = format!(
                    "move at=({:.1},{:.1}) pressed={:?} dragging={} mods={:?}",
                    event.position.x.to_f64(),
                    event.position.y.to_f64(),
                    event.pressed_button,
                    event.dragging(),
                    event.modifiers
                );
                cx.notify();
            },
        );

        let on_mouse_up = cx.listener(
            |probe, event: &MouseUpEvent, _window: &mut Window, cx: &mut Context<Self>| {
                probe.mouse_ups += 1;
                probe.last_mouse = format!(
                    "up={:?} at=({:.1},{:.1}) mods={:?}",
                    event.button,
                    event.position.x.to_f64(),
                    event.position.y.to_f64(),
                    event.modifiers
                );
                cx.notify();
            },
        );

        let drag_capture_entity = cx.entity();

        div()
            .size_full()
            .bg(rgb(0x101216))
            .text_color(rgb(0xe5e7eb))
            .font_family("monospace")
            .track_focus(&self.focus)
            .on_key_down(on_key)
            .on_scroll_wheel(on_scroll)
            .on_any_mouse_down(on_mouse_down)
            .capture_any_mouse_up(on_mouse_up)
            .on_mouse_move(on_mouse_move)
            .child(
                div()
                    .p_4()
                    .child(format!(
                        "ticks={} last_key={} scrolls={} last_scroll={} right_clicks={} mouse_downs={} mouse_ups={} mouse_moves={} captured_drag_moves={} last_mouse={} clipboard_copies={} focus=click surface then type/scroll/drag/right-click; secondary+C copies probe text",
                        self.ticks,
                        self.last_key,
                        self.scroll_events,
                        self.last_scroll,
                        self.right_clicks,
                        self.mouse_downs,
                        self.mouse_ups,
                        self.mouse_moves,
                        self.captured_drag_moves,
                        self.last_mouse,
                        self.copied,
                    )),
            )
            .child(
                canvas(
                    move |_bounds, window, _cx: &mut App| {
                        window.on_mouse_event(move |event: &MouseMoveEvent, _phase, _window, cx| {
                            if !event.dragging() {
                                return;
                            }

                            let last_mouse = format!(
                                "captured_drag at=({:.1},{:.1}) pressed={:?} mods={:?}",
                                event.position.x.to_f64(),
                                event.position.y.to_f64(),
                                event.pressed_button,
                                event.modifiers
                            );

                            drag_capture_entity.update(cx, |probe, cx| {
                                probe.captured_drag_moves += 1;
                                probe.last_mouse = last_mouse;
                                cx.notify();
                            });
                        });
                    },
                    |bounds: Bounds<gpui::Pixels>, (), window: &mut Window, _cx: &mut App| {
                        let cell_w = px(12.0);
                        let cell_h = px(20.0);
                        let origin = point(bounds.origin.x + px(24.0), bounds.origin.y + px(96.0));
                        for row in 0..12 {
                            for col in 0..40 {
                                let bg = if (row + col) % 2 == 0 {
                                    rgb(0x172033)
                                } else {
                                    rgb(0x111827)
                                };
                                window.paint_quad(fill(
                                    Bounds::new(
                                        point(
                                            origin.x + cell_w * col as f32,
                                            origin.y + cell_h * row as f32,
                                        ),
                                        size(cell_w - px(1.0), cell_h - px(1.0)),
                                    ),
                                    bg,
                                ));
                            }
                        }
                    },
                )
                .w_full()
                .h(px(360.0)),
            )
    }
}

fn main() {
    Application::new().run(|cx| {
        cx.open_window(WindowOptions::default(), |_, cx| cx.new(TerminalProbe::new))
            .unwrap();
    });
}
