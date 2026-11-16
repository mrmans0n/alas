// PROTOTYPE, throwaway: the app run.sh installs in a scratch simulator. It
// appends one line per thing that reaches it to Documents/events.log, which
// run.sh reads from the host.
import CoreLocation
import os
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "io.nlopez.alas.simslim-probe", category: "probe")

func record(_ event: String) {
    logger.notice("probe \(event, privacy: .public)")
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("events.log")
    let line = Data((event + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

final class Delegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var lastLocation = ""

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        record("launched")
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Provisional authorization is granted without a prompt nobody is there to tap.
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            record("auth granted=\(granted)")
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        location.delegate = self
        location.startUpdatingLocation()
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        record("token ok bytes=\(token.count)")
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        record("token-error \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        record("push \(notification.request.content.body)")
        completionHandler([])
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let text = String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
        guard text != lastLocation else { return }
        lastLocation = text
        record("location \(text)")
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        record("location-error \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        record("location-auth \(manager.authorizationStatus.rawValue)")
        manager.startUpdatingLocation()
    }
}

@main
struct ProbeApp: App {
    @UIApplicationDelegateAdaptor(Delegate.self) private var delegate

    var body: some Scene {
        WindowGroup { Text("simslim probe") }
    }
}
