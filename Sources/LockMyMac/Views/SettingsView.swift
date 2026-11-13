import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Surveillance") {
                LabeledContent("État", value: model.statusLine)
                Toggle("Surveillance active", isOn: $model.monitoringEnabled).disabled(!model.isEnrolled)
                Picker("Caméra", selection: $model.cameraID) {
                    Text("Automatique (caméra intégrée)").tag("")
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                Picker("Vérification", selection: $model.checkInterval) {
                    Text("En continu").tag(0.0)
                    Text("Toutes les 30 secondes").tag(30.0)
                    Text("Toutes les minutes").tag(60.0)
                    Text("Toutes les 2 minutes").tag(120.0)
                    Text("Toutes les 5 minutes").tag(300.0)
                }
                Text(model.checkInterval > 0
                     ? "La caméra s'allume quelques secondes à chaque vérification. Deux vérifications de suite sans vous reconnaître verrouillent la session : entre \(Int(model.checkInterval)) et \(Int(model.checkInterval * 2)) secondes après votre départ. Le délai ci-dessous ne sert qu'en mode continu et en mode test."
                     : "La caméra reste allumée et la session se verrouille après le délai ci-dessous sans vous reconnaître.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Délai avant verrouillage") {
                    HStack {
                        Slider(value: $model.lockDelay, in: 3...120, step: 1)
                        Text("\(Int(model.lockDelay)) s").monospacedDigit().frame(width: 44)
                    }
                }
                Toggle("Verrouiller si la caméra reste indisponible", isOn: $model.lockOnCameraFailure)
                Text("Par défaut, une caméra indisponible interrompt la protection et l'app vous prévient. Cochez pour verrouiller à la place, après le délai ci-dessus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lieux sans surveillance") {
                if model.exemptNetworks.isEmpty {
                    Text("Aucun : la surveillance s'applique partout.").foregroundStyle(.secondary)
                }
                ForEach(model.exemptNetworks, id: \.self) { ssid in
                    HStack {
                        Label(ssid, systemImage: ssid == model.currentNetwork ? "wifi" : "house")
                        Spacer()
                        Button("Retirer") { model.setExempt(ssid, false) }
                    }
                }
                Button(model.currentNetwork.map { "Ajouter le Wi-Fi actuel (« \($0) »)" } ?? "Ajouter le Wi-Fi actuel…") {
                    model.exemptCurrentNetwork()
                }
                .disabled(model.currentNetwork.map(model.exemptNetworks.contains) ?? false)
                Text("Sur ces réseaux Wi-Fi (chez vous, par exemple), la surveillance se suspend et la caméra reste éteinte. Partout ailleurs — bureau, réseau inconnu, câble, pas de réseau — elle est active. macOS exige l'autorisation « Service de localisation » pour lire le nom du Wi-Fi ; lockMyMac ne lit que ce nom, pas votre position.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.locationDenied, !model.exemptNetworks.isEmpty {
                    Label("Localisation refusée : lockMyMac ne peut plus reconnaître ces réseaux et surveille donc partout.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Reconnaissance") {
                LabeledContent("Seuil") {
                    HStack {
                        Slider(value: $model.threshold, in: 0.30...0.85)
                        Text(String(format: "%.2f", model.threshold)).monospacedDigit().frame(width: 44)
                        Button("Défaut") { model.threshold = AppModel.defaultThreshold }
                    }
                }
                Button("Mode test…") { model.showTest() }.disabled(!model.isEnrolled)
            }
            Section("Mon visage") {
                LabeledContent("Empreintes", value: model.isEnrolled ? "Enregistrées sur ce Mac" : "Aucune")
                HStack {
                    Button(model.isEnrolled ? "Enregistrer à nouveau…" : "Enregistrer…") { model.showEnrollment() }
                    Button("Supprimer…", role: .destructive) { model.deleteFace() }.disabled(!model.isEnrolled)
                    Spacer()
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([TemplateStore.fileURL])
                    }.disabled(!model.isEnrolled)
                }
                Text("Seules des empreintes numériques sont stockées, jamais d'image. Aucune donnée ne quitte ce Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Général") {
                Toggle("Lancer au démarrage", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Button("Verrouiller maintenant") { model.lockNow() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 800)
    }
}
