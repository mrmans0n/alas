use std::sync::Once;

use block2::RcBlock;
use objc2::{
    MainThreadOnly, define_class, msg_send,
    rc::{Retained, autoreleasepool},
    runtime::{Bool, ProtocolObject},
};
use objc2_app_kit::NSApplication;
use objc2_foundation::{
    MainThreadMarker, NSDictionary, NSError, NSObject, NSObjectProtocol, NSString,
};
use objc2_user_notifications::{
    UNAuthorizationOptions, UNMutableNotificationContent, UNNotification,
    UNNotificationPresentationOptions, UNNotificationRequest, UNNotificationResponse,
    UNNotificationSound, UNUserNotificationCenter, UNUserNotificationCenterDelegate,
};

use crate::notifications::{
    AppFocusState, HarnessCompletionEvent, NotificationActivation, NotificationActivationPayload,
    NotificationActivationResolution, NotificationActivationToken, NotificationSink,
    NotificationSound, activation_kind_key, activation_repo_id_key, activation_terminal_tab_id_key,
    activation_token_key, activation_worktree_path_key, enqueue_notification_activation,
    register_harness_completion_activation, resolve_notification_activation,
};

static INSTALL_DELEGATE: Once = Once::new();

#[derive(Clone, Copy, Debug, Default)]
pub struct MacOsAppFocusState;

impl AppFocusState for MacOsAppFocusState {
    fn is_app_active(&self) -> bool {
        let Some(mtm) = MainThreadMarker::new() else {
            return false;
        };
        let app = NSApplication::sharedApplication(mtm);
        app.isActive()
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct MacOsNotificationSink;

impl NotificationSink for MacOsNotificationSink {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()> {
        post_harness_completion(event)
    }
}

#[derive(Debug, Default)]
struct NotificationDelegateIvars;

define_class!(
    // SAFETY:
    // - `NSObject` has no subclassing requirements.
    // - `NotificationDelegate` does not implement `Drop`.
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    #[ivars = NotificationDelegateIvars]
    struct NotificationDelegate;

    // SAFETY: `NSObjectProtocol` has no safety requirements.
    unsafe impl NSObjectProtocol for NotificationDelegate {}

    // SAFETY: Method signatures match `UNUserNotificationCenterDelegate`.
    unsafe impl UNUserNotificationCenterDelegate for NotificationDelegate {
        #[unsafe(method(userNotificationCenter:willPresentNotification:withCompletionHandler:))]
        fn will_present(
            &self,
            _center: &UNUserNotificationCenter,
            _notification: &UNNotification,
            completion_handler: &block2::DynBlock<dyn Fn(UNNotificationPresentationOptions)>,
        ) {
            completion_handler.call((UNNotificationPresentationOptions::Banner
                | UNNotificationPresentationOptions::List
                | UNNotificationPresentationOptions::Sound,));
        }

        #[unsafe(method(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:))]
        fn did_receive(
            &self,
            _center: &UNUserNotificationCenter,
            response: &UNNotificationResponse,
            completion_handler: &block2::DynBlock<dyn Fn()>,
        ) {
            activate_app();

            if let Some(payload) = activation_payload_from_response(response)
                && let NotificationActivationResolution::Resolved(target) =
                    resolve_notification_activation(Some(payload))
            {
                enqueue_notification_activation(NotificationActivation::HarnessCompletion(target));
            }

            completion_handler.call(());
        }
    }
);

impl NotificationDelegate {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(NotificationDelegateIvars);
        // SAFETY: `NSObject`'s `init` signature is correct.
        unsafe { msg_send![super(this), init] }
    }
}

fn post_harness_completion(event: HarnessCompletionEvent) -> anyhow::Result<()> {
    install_delegate();

    let payload = event
        .activation_target()
        .map(register_harness_completion_activation);

    autoreleasepool(|_| {
        let center = UNUserNotificationCenter::currentNotificationCenter();
        request_authorization(&center);

        let content = UNMutableNotificationContent::new();
        content.setTitle(&NSString::from_str(&event.title));
        content.setBody(&NSString::from_str(&event.body));
        content.setSound(Some(&notification_sound(event.sound)));

        if let Some(payload) = payload.as_ref() {
            set_user_info(&content, payload);
        }

        let identifier = NSString::from_str(&notification_identifier(payload.as_ref()));
        let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
            &identifier,
            &content,
            None,
        );

        center.addNotificationRequest_withCompletionHandler(&request, None);
    });

    Ok(())
}

pub(crate) fn install_delegate() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };

    INSTALL_DELEGATE.call_once(|| {
        autoreleasepool(|_| {
            let center = UNUserNotificationCenter::currentNotificationCenter();
            let delegate = NotificationDelegate::new(mtm);
            center.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
            // UNUserNotificationCenter keeps a weak delegate reference, so the
            // delegate must intentionally live for the process lifetime.
            let _leaked = Retained::into_raw(delegate);
        });
    });
}

fn request_authorization(center: &UNUserNotificationCenter) {
    let completion = RcBlock::new(|_granted: Bool, _error: *mut NSError| {});
    center.requestAuthorizationWithOptions_completionHandler(
        UNAuthorizationOptions::Alert | UNAuthorizationOptions::Sound,
        &completion,
    );
}

fn notification_sound(sound: NotificationSound) -> Retained<UNNotificationSound> {
    match sound {
        NotificationSound::Success => UNNotificationSound::defaultSound(),
        NotificationSound::Failure => {
            let sound_name = NSString::from_str("Basso");
            UNNotificationSound::soundNamed(&sound_name)
        }
    }
}

fn set_user_info(content: &UNMutableNotificationContent, payload: &NotificationActivationPayload) {
    let entries = payload.user_info_entries();
    let keys = entries
        .iter()
        .map(|(key, _)| NSString::from_str(key))
        .collect::<Vec<_>>();
    let values = entries
        .iter()
        .map(|(_, value)| NSString::from_str(value))
        .collect::<Vec<_>>();
    let key_refs = keys.iter().map(|key| &**key).collect::<Vec<_>>();
    let value_refs = values.iter().map(|value| &**value).collect::<Vec<_>>();
    let user_info = NSDictionary::from_slices(&key_refs, &value_refs);

    // SAFETY: `userInfo` accepts a property-list dictionary. The dictionary only
    // contains `NSString` keys and values, which are valid property-list values.
    unsafe {
        let _: () = msg_send![content, setUserInfo: &*user_info];
    }
}

fn activation_payload_from_response(
    response: &UNNotificationResponse,
) -> Option<NotificationActivationPayload> {
    autoreleasepool(|pool| {
        let notification = response.notification();
        let content = notification.request().content();
        let user_info = content.userInfo();

        let kind_key = NSString::from_str(activation_kind_key());
        let token_key = NSString::from_str(activation_token_key());
        let repo_id_key = NSString::from_str(activation_repo_id_key());
        let worktree_path_key = NSString::from_str(activation_worktree_path_key());
        let terminal_tab_id_key = NSString::from_str(activation_terminal_tab_id_key());
        // SAFETY: Alas writes string values for these keys in `set_user_info`.
        let kind: Option<Retained<NSString>> =
            unsafe { msg_send![&*user_info, objectForKey: &*kind_key] };
        // SAFETY: Alas writes string values for these keys in `set_user_info`.
        let token: Option<Retained<NSString>> =
            unsafe { msg_send![&*user_info, objectForKey: &*token_key] };
        // SAFETY: Alas writes string values for these keys in `set_user_info`.
        let repo_id: Option<Retained<NSString>> =
            unsafe { msg_send![&*user_info, objectForKey: &*repo_id_key] };
        // SAFETY: Alas writes string values for these keys in `set_user_info`.
        let worktree_path: Option<Retained<NSString>> =
            unsafe { msg_send![&*user_info, objectForKey: &*worktree_path_key] };
        // SAFETY: Alas writes string values for these keys in `set_user_info`.
        let terminal_tab_id: Option<Retained<NSString>> =
            unsafe { msg_send![&*user_info, objectForKey: &*terminal_tab_id_key] };

        let kind = kind.as_deref().map(|value| {
            // SAFETY: The returned `&str` is used only within this autorelease pool.
            unsafe { value.to_str(pool).to_string() }
        });
        let token = token.as_deref().map(|value| {
            // SAFETY: The returned `&str` is used only within this autorelease pool.
            unsafe { value.to_str(pool).to_string() }
        });
        let repo_id = repo_id.as_deref().map(|value| {
            // SAFETY: The returned `&str` is used only within this autorelease pool.
            unsafe { value.to_str(pool).to_string() }
        });
        let worktree_path = worktree_path.as_deref().map(|value| {
            // SAFETY: The returned `&str` is used only within this autorelease pool.
            unsafe { value.to_str(pool).to_string() }
        });
        let terminal_tab_id = terminal_tab_id.as_deref().map(|value| {
            // SAFETY: The returned `&str` is used only within this autorelease pool.
            unsafe { value.to_str(pool).to_string() }
        });

        NotificationActivationPayload::from_user_info_values(
            kind.as_deref(),
            token.as_deref(),
            repo_id.as_deref(),
            worktree_path.as_deref(),
            terminal_tab_id.as_deref(),
        )
    })
}

fn notification_identifier(payload: Option<&NotificationActivationPayload>) -> String {
    match payload {
        Some(payload) => format!(
            "alas-harness-completion-{}",
            payload
                .token
                .as_ref()
                .map(NotificationActivationToken::as_str)
                .unwrap_or("untokened")
        ),
        None => format!("alas-harness-completion-{}", uuid_fallback()),
    }
}

fn uuid_fallback() -> String {
    static NEXT_NOTIFICATION_ID: std::sync::atomic::AtomicU64 =
        std::sync::atomic::AtomicU64::new(1);
    let id = NEXT_NOTIFICATION_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{}-{id}", std::process::id())
}

fn activate_app() {
    if let Some(mtm) = MainThreadMarker::new() {
        let app = NSApplication::sharedApplication(mtm);
        #[allow(deprecated)]
        app.activateIgnoringOtherApps(true);
    }
}
