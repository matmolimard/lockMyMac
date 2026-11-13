import SwiftUI

/// Mode test : même chaîne que la surveillance réelle, mais le verrouillage est seulement affiché.
struct TestView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Mode test — aucun verrouillage réel tant que cette fenêtre est ouverte", systemImage: "testtube.2")
                .font(.callout.bold())
                .foregroundStyle(.orange)
            PreviewWithFaces(model: model)
            status
            Divider()
            LabeledContent("Seuil de reconnaissance") {
                HStack {
                    Slider(value: $model.threshold, in: 0.30...0.85)
                    Text(String(format: "%.2f", model.threshold)).monospacedDigit().frame(width: 40)
                }
            }
            Text("Le score affiché sur chaque visage doit rester nettement au-dessus du seuil pour vous, et en dessous pour les autres. Plus haut = plus strict (moins de risque d'accepter quelqu'un d'autre, plus de verrouillages intempestifs).")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Délai avant verrouillage") {
                HStack {
                    Slider(value: $model.lockDelay, in: 3...60, step: 1)
                    Text("\(Int(model.lockDelay)) s").monospacedDigit().frame(width: 40)
                }
            }
            HStack {
                if !model.monitoringEnabled {
                    Text("La surveillance réelle est suspendue.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.monitoringEnabled ? "Fermer" : "Activer la surveillance et fermer") {
                    model.monitoringEnabled = true
                    model.windows.close(id: "test")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private var status: some View {
        let (text, detail, color, symbol): (String, String, Color, String) = {
            switch model.state {
            case .recognized:
                return ("Visage reconnu", "Le compteur est à zéro.", .green, "person.crop.circle.badge.checkmark")
            case .absent(let s) where model.testLockFired || s == 0:
                return ("VERROUILLAGE (simulé)", "En surveillance réelle, la session serait verrouillée maintenant.", .red, "lock.fill")
            case .absent(let s):
                return ("Absence — verrouillage dans \(s) s", "Votre visage n'est pas reconnu. Les visages inconnus n'arrêtent pas le compte à rebours.", .orange, "timer")
            case .cameraUnavailable(let reason):
                return ("Caméra indisponible — protection interrompue", reason, .red, "exclamationmark.triangle.fill")
            case .starting:
                return ("Démarrage de la caméra…", "", .secondary, "camera")
            default:
                return (model.statusLine, "", .secondary, "pause.circle")
            }
        }()
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.title3.bold()).foregroundStyle(color)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
    }
}
