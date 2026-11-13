import SwiftUI

struct EnrollmentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.enrollment.phase {
            case .intro: intro
            case .capturing: capturing
            case .done: done
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Enregistrer mon visage", systemImage: "person.crop.circle.badge.plus").font(.title2.bold())
            Text("lockMyMac verrouille votre session quand **votre** visage n'est plus devant l'écran, même si quelqu'un d'autre y reste.")
            Text("Pour cela, l'app va mémoriser votre visage sous cinq angles (face, gauche, droite, haut, bas). Comptez une vingtaine de secondes.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Soyez seul dans le champ, visage bien éclairé.", systemImage: "lightbulb")
                Label("Aucune photo n'est conservée : seules des empreintes numériques restent sur ce Mac.", systemImage: "lock.shield")
                Label("Rien n'est envoyé sur Internet. Vous pourrez tout supprimer depuis le menu.", systemImage: "wifi.slash")
            }
            .foregroundStyle(.secondary)
            if model.isEnrolled {
                Text("Un visage est déjà enregistré : il sera remplacé à la fin du parcours.").font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Commencer") { model.beginEnrollmentCapture() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var capturing: some View {
        let progress = model.enrollment
        let steps = EnrollmentProgress.steps
        let step = steps[min(progress.stepIndex, steps.count - 1)]
        let total = steps.count * EnrollmentProgress.samplesPerStep
        let made = progress.stepIndex * EnrollmentProgress.samplesPerStep + progress.capturedInStep
        return VStack(alignment: .leading, spacing: 12) {
            PreviewWithFaces(model: model, showFaces: false)
            Label("Étape \(min(progress.stepIndex + 1, steps.count)) sur \(steps.count) — \(step.title)", systemImage: step.symbol)
                .font(.title3.bold())
            Text(progress.hint.isEmpty ? step.instruction : progress.hint)
                .foregroundStyle(.secondary)
                .frame(minHeight: 34, alignment: .topLeading)
            ProgressView(value: Double(made), total: Double(total))
            HStack {
                Button("Annuler") { model.windows.close(id: "enroll") }
                Spacer()
                Button("Capturer cette position") { model.captureEnrollmentManually() }
                    .help("À utiliser si l'app ne détecte pas la position demandée.")
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Visage enregistré", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green)
            Text("Avant d'activer la protection, vérifiez en **mode test** que vous êtes bien reconnu à votre poste habituel : le compte à rebours s'affiche, mais rien ne se verrouille.")
            Text("La surveillance n'est pas encore active.").foregroundStyle(.secondary)
            HStack {
                Button("Activer la surveillance") {
                    model.monitoringEnabled = true
                    model.windows.close(id: "enroll")
                }
                Spacer()
                Button("Ouvrir le mode test") {
                    model.windows.close(id: "enroll")
                    model.showTest()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
