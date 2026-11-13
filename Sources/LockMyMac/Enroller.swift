import Foundation
import LockMyMacCore

struct EnrollmentProgress: Equatable {
    enum Phase { case intro, capturing, done }
    var phase: Phase = .intro
    var stepIndex = 0
    var capturedInStep = 0
    var hint = ""

    static let steps: [(title: String, instruction: String, symbol: String)] = [
        ("De face", "Regardez l'écran, bien en face.", "face.smiling"),
        ("Vers la gauche", "Tournez légèrement la tête vers la gauche.", "arrow.left"),
        ("Vers la droite", "Tournez légèrement la tête vers la droite.", "arrow.right"),
        ("Vers le haut", "Levez légèrement le menton.", "arrow.up"),
        ("Vers le bas", "Baissez légèrement le menton.", "arrow.down"),
    ]
    static let samplesPerStep = 3
}

/// Parcours d'enregistrement : quelques empreintes par position de tête.
/// Les positions variées rendent la reconnaissance tolérante aux petits mouvements du quotidien.
struct Enroller {
    var forceNext = false
    private var collected: [[Float]] = []
    private var reference: [Float]?
    private var lastCapture: TimeInterval = 0
    private var sideSign: Double = 0
    private var tiltSign: Double = 0

    /// Renvoie les empreintes quand le parcours est terminé.
    mutating func ingest(_ faces: [DetectedFace], now: TimeInterval, progress: inout EnrollmentProgress) -> [[Float]]? {
        guard progress.phase == .capturing, progress.stepIndex < EnrollmentProgress.steps.count else { return nil }
        let step = EnrollmentProgress.steps[progress.stepIndex]
        guard !faces.isEmpty else { progress.hint = "Aucun visage détecté. Placez-vous face à la caméra."; return nil }
        guard faces.count == 1, let face = faces.first else {
            progress.hint = "Plusieurs visages détectés : vous devez être seul dans le champ."
            return nil
        }
        guard let embedding = face.embedding, face.box.width >= 0.16 else {
            progress.hint = "Rapprochez-vous de la caméra."
            return nil
        }
        if let reference, FaceMatcher.cosine(embedding, reference) < 0.3 {
            progress.hint = "Ce visage ne ressemble pas à celui du début. Restez seul devant la caméra."
            return nil
        }
        let forced = forceNext
        if !forced, !poseMatches(step: progress.stepIndex, yaw: face.yaw, pitch: face.pitch) {
            progress.hint = step.instruction
            return nil
        }
        progress.hint = "Parfait, ne bougez plus…"
        guard forced || now - lastCapture >= 0.5 else { return nil }
        forceNext = false
        lastCapture = now
        collected.append(embedding)
        if reference == nil { reference = embedding }
        // On retient de quel côté l'utilisateur a tourné, pour exiger l'autre côté à l'étape suivante.
        if progress.stepIndex == 1, let yaw = face.yaw, sideSign == 0 { sideSign = yaw < 0 ? -1 : 1 }
        if progress.stepIndex == 3, let pitch = face.pitch, tiltSign == 0 { tiltSign = pitch < 0 ? -1 : 1 }
        progress.capturedInStep += 1
        if progress.capturedInStep >= EnrollmentProgress.samplesPerStep {
            progress.stepIndex += 1
            progress.capturedInStep = 0
            if progress.stepIndex >= EnrollmentProgress.steps.count { return collected }
            progress.hint = EnrollmentProgress.steps[progress.stepIndex].instruction
        }
        return nil
    }

    /// Angles en degrés. Vision ne les fournit pas toujours : sans mesure, on fait confiance à l'utilisateur.
    private func poseMatches(step: Int, yaw: Double?, pitch: Double?) -> Bool {
        switch step {
        case 0:
            return abs(yaw ?? 0) < 12 && abs(pitch ?? 0) < 15
        case 1:
            guard let yaw else { return true }
            return (12...45).contains(abs(yaw))
        case 2:
            guard let yaw else { return true }
            return (12...45).contains(abs(yaw)) && (sideSign == 0 || yaw * sideSign < 0)
        case 3:
            guard let pitch else { return true }
            return (7...40).contains(abs(pitch))
        default:
            guard let pitch else { return true }
            return (7...40).contains(abs(pitch)) && (tiltSign == 0 || pitch * tiltSign < 0)
        }
    }
}
