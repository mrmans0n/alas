import Foundation

// launchd starts this service on Alas's first message and restarts it after a crash.
let delegate = SimServiceListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
