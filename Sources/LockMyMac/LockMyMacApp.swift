import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--compare") {
            exit(CompareCommand.run(Array(CommandLine.arguments.drop { $0 != "--compare" }.dropFirst())))
        }
        LockMyMacApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}

struct LockMyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.symbolName)
            if let text = model.menuBarText { Text(text).monospacedDigit() }
        }
        .accessibilityLabel("lockMyMac : \(model.statusLine)")
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    private var delays: [Double] {
        let presets: [Double] = [5, 10, 15, 20, 30, 45, 60]
        return presets.contains(model.lockDelay) ? presets : (presets + [model.lockDelay]).sorted()
    }

    var body: some View {
        Text(model.statusLine)
        if case .cameraUnavailable(let reason) = model.state { Text(reason) }
        if case .modelMissing(let reason) = model.state { Text(reason) }
        if let error = model.lastError {
            Button("⚠︎ \(error) (effacer)") { model.lastError = nil }
        }
        Divider()
        Toggle("Surveillance active", isOn: $model.monitoringEnabled)
            .disabled(!model.isEnrolled)
        if let ssid = model.currentNetwork {
            Toggle("Ne pas surveiller sur le Wi-Fi « \(ssid) »",
                   isOn: Binding(get: { model.exemptNetworks.contains(ssid) }, set: { model.setExempt(ssid, $0) }))
        } else {
            Button("Ne pas surveiller sur le Wi-Fi actuel…") { model.exemptCurrentNetwork() }
        }
        Button("Verrouiller maintenant") { model.lockNow() }
            .keyboardShortcut("l")
        Divider()
        Picker("Caméra", selection: $model.cameraID) {
            Text("Automatique (caméra intégrée)").tag("")
            ForEach(model.cameras) { Text($0.name).tag($0.id) }
            if !model.cameraID.isEmpty, !model.cameras.contains(where: { $0.id == model.cameraID }) {
                Text("Caméra choisie (absente)").tag(model.cameraID)
            }
        }
        Picker("Vérification", selection: $model.checkInterval) {
            Text("En continu (voyant toujours allumé)").tag(0.0)
            Text("Toutes les 30 secondes").tag(30.0)
            Text("Toutes les minutes").tag(60.0)
            Text("Toutes les 2 minutes").tag(120.0)
            Text("Toutes les 5 minutes").tag(300.0)
        }
        Picker(model.checkInterval > 0 ? "Délai (mode continu seulement)" : "Délai avant verrouillage", selection: $model.lockDelay) {
            ForEach(delays, id: \.self) { Text("\(Int($0)) secondes").tag($0) }
        }
        Divider()
        Button("Mode test…") { model.showTest() }
            .disabled(!model.isEnrolled)
        Button(model.isEnrolled ? "Enregistrer à nouveau mon visage…" : "Enregistrer mon visage…") { model.showEnrollment() }
        Button("Supprimer mon visage…") { model.deleteFace() }
            .disabled(!model.isEnrolled)
        Divider()
        Toggle("Lancer au démarrage", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Button("Réglages…") { model.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quitter lockMyMac") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Fenêtres classiques (enregistrement, test, réglages) pour une app qui vit dans la barre des menus.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    func show<Content: View>(id: String, title: String, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.identifier = NSUserInterfaceItemIdentifier(id)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            windows[id] = window
            closeHandlers[id] = onClose
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        window.contentViewController = nil   // libère la vue (et l'aperçu caméra)
        windows[id] = nil
        closeHandlers.removeValue(forKey: id)?()
    }
}
