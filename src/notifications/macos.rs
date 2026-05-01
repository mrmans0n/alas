#![allow(clashing_extern_declarations)]

use std::ffi::{c_char, c_void};

use crate::notifications::{
    AppFocusState, HarnessCompletionEvent, NotificationSink, NotificationSound,
};

type ObjcId = *mut c_void;
type Sel = *mut c_void;

#[link(name = "objc")]
unsafe extern "C" {
    fn objc_getClass(name: *const c_char) -> ObjcId;
    fn sel_registerName(name: *const c_char) -> Sel;

    #[link_name = "objc_msgSend"]
    fn msg_send_id(receiver: ObjcId, selector: Sel) -> ObjcId;

    #[link_name = "objc_msgSend"]
    fn msg_send_bool(receiver: ObjcId, selector: Sel) -> bool;

    #[link_name = "objc_msgSend"]
    fn msg_send_void_id(receiver: ObjcId, selector: Sel, value: ObjcId);

    #[link_name = "objc_msgSend"]
    fn msg_send_id_bytes(
        receiver: ObjcId,
        selector: Sel,
        bytes: *const u8,
        length: usize,
        encoding: usize,
    ) -> ObjcId;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct MacOsAppFocusState;

impl AppFocusState for MacOsAppFocusState {
    fn is_app_active(&self) -> bool {
        unsafe {
            let app = send_id(class("NSApplication"), selector("sharedApplication"));
            !app.is_null() && send_bool(app, selector("isActive"))
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct MacOsNotificationSink;

impl NotificationSink for MacOsNotificationSink {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()> {
        unsafe {
            let notification = send_id(class("NSUserNotification"), selector("new"));
            if notification.is_null() {
                anyhow::bail!("failed to allocate NSUserNotification");
            }

            let title = ns_string(&event.title);
            let body = ns_string(&event.body);
            if title.is_null() || body.is_null() {
                release_if_present(title);
                release_if_present(body);
                release_if_present(notification);
                anyhow::bail!("failed to allocate notification strings");
            }

            send_void_id(notification, selector("setTitle:"), title);
            send_void_id(notification, selector("setInformativeText:"), body);

            if let Some(sound_name) = notification_sound_name(event.sound) {
                let sound = ns_string(sound_name);
                if !sound.is_null() {
                    send_void_id(notification, selector("setSoundName:"), sound);
                    release_if_present(sound);
                }
            }

            let center = send_id(
                class("NSUserNotificationCenter"),
                selector("defaultUserNotificationCenter"),
            );
            if center.is_null() {
                release_if_present(title);
                release_if_present(body);
                release_if_present(notification);
                anyhow::bail!("failed to resolve NSUserNotificationCenter");
            }

            send_void_id(center, selector("deliverNotification:"), notification);
            release_if_present(title);
            release_if_present(body);
            release_if_present(notification);
        }

        Ok(())
    }
}

fn notification_sound_name(sound: NotificationSound) -> Option<&'static str> {
    match sound {
        NotificationSound::Success => Some("Glass"),
        NotificationSound::Failure => Some("Basso"),
    }
}

unsafe fn class(name: &str) -> ObjcId {
    let name = nul_terminated(name);
    unsafe { objc_getClass(name.as_ptr().cast()) }
}

unsafe fn selector(name: &str) -> Sel {
    let name = nul_terminated(name);
    unsafe { sel_registerName(name.as_ptr().cast()) }
}

unsafe fn send_id(receiver: ObjcId, selector: Sel) -> ObjcId {
    unsafe { msg_send_id(receiver, selector) }
}

unsafe fn send_bool(receiver: ObjcId, selector: Sel) -> bool {
    unsafe { msg_send_bool(receiver, selector) }
}

unsafe fn send_void_id(receiver: ObjcId, selector: Sel, value: ObjcId) {
    unsafe { msg_send_void_id(receiver, selector, value) }
}

unsafe fn ns_string(value: &str) -> ObjcId {
    let string = unsafe { send_id(class("NSString"), selector("alloc")) };
    if string.is_null() {
        return string;
    }

    unsafe {
        msg_send_id_bytes(
            string,
            selector("initWithBytes:length:encoding:"),
            value.as_ptr(),
            value.len(),
            4,
        )
    }
}

unsafe fn release_if_present(object: ObjcId) {
    if !object.is_null() {
        unsafe {
            send_id(object, selector("release"));
        }
    }
}

fn nul_terminated(value: &str) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(value.len() + 1);
    bytes.extend_from_slice(value.as_bytes());
    bytes.push(0);
    bytes
}
