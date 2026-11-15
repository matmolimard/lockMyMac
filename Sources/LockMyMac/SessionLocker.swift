import AppKit
import CoreGraphics

/// Verrouillage réel de la session macOS et observation de son état.
enum SessionLocker {
    /// Déclenche l'écran de verrouillage du système (le même que ⌃⌘Q).
    ///
    /// macOS n'offre aucune API publique pour cela. On appelle `SACLockScreenImmediate`
    /// du framework privé `login.framework`, la fonction qu'utilise le système lui-même.
    /// Si elle disparaît dans une future version, on se rabat sur la mise en veille de l'écran,
    /// qui ne verrouille que si « Exiger le mot de passe immédiatement » est réglé.
    /// L'appelant vérifie ensuite `isScreenLocked` : on n'affirme jamais avoir verrouillé sans contrôle.
    static func lockNow() {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    private static var sessionInfo: [String: Any] {
        (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    }

    static var isScreenLocked: Bool {
        (sessionInfo["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Faux quand un autre utilisateur occupe l'écran (permutation rapide d'utilisateur).
    static var isOnConsole: Bool {
        (sessionInfo[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue ?? true
    }

    static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}

/// Prévient quand l'état de la session change (verrouillage, veille, réveil, changement d'utilisateur).
final class SessionObserver {
    enum Event { case willSleep, didWake, changed }
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(handler: @escaping (Event) -> Void) {
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler(event) }
            tokens.append((center, token))
        }
        on(ws, NSWorkspace.willSleepNotification, .willSleep)
        on(ws, NSWorkspace.didWakeNotification, .didWake)
        on(ws, NSWorkspace.screensDidSleepNotification, .changed)
        on(ws, NSWorkspace.screensDidWakeNotification, .changed)
        on(ws, NSWorkspace.sessionDidResignActiveNotification, .changed)
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification, .changed)
        on(dist, Notification.Name("com.apple.screenIsLocked"), .changed)
        on(dist, Notification.Name("com.apple.screenIsUnlocked"), .changed)
    }

    deinit { tokens.forEach { $0.0.removeObserver($0.1) } }
}
