import Foundation

// The parts of UserNotifications the services build notices with, where the
// framework doesn't exist. There is no notification center there: a host
// relays every notice to its clients (`AlasHost.relayNotifications`), and
// anything else is dropped.
#if !canImport(UserNotifications)
public typealias UNNotificationContent = UNMutableNotificationContent

public final class UNMutableNotificationContent: @unchecked Sendable {
    public var title = ""
    public var subtitle = ""
    public var body = ""
    public var userInfo: [AnyHashable: Any] = [:]
    public var threadIdentifier = ""
    public var sound: UNNotificationSound?
    public var attachments: [UNNotificationAttachment] = []

    public init() {}
}

public struct UNNotificationSound: Sendable {
    public static let `default` = UNNotificationSound()
}

public final class UNNotificationAttachment: Sendable {
    public let identifier: String
    public let url: URL

    public init(identifier: String, url: URL, options: [AnyHashable: Any]?) throws {
        self.identifier = identifier
        self.url = url
    }
}

public class UNNotificationTrigger: @unchecked Sendable {}

public final class UNNotificationRequest: @unchecked Sendable {
    public let identifier: String
    public let content: UNNotificationContent
    public let trigger: UNNotificationTrigger?

    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        self.identifier = identifier
        self.content = content
        self.trigger = trigger
    }
}
#endif
