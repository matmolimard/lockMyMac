import Foundation

/// Réglages du moteur de décision.
public struct PresenceConfig: Equatable, Sendable {
    /// Durée sans reconnaissance du propriétaire avant verrouillage.
    public var lockDelay: TimeInterval
    /// Durée sans reconnaissance avant d'afficher « absence en cours ».
    /// Purement cosmétique : le compte à rebours part toujours de la dernière reconnaissance.
    public var absenceGrace: TimeInterval
    /// Une fois l'absence déclarée, nombre d'images consécutives reconnues
    /// nécessaires pour annuler le compte à rebours (limite l'effet d'une fausse acceptation isolée).
    public var confirmFrames: Int
    /// Trou maximal entre deux `tick` avant de considérer que le temps a « sauté »
    /// (veille, processus suspendu) : on repart alors de zéro au lieu de verrouiller à l'aveugle.
    public var maxTickGap: TimeInterval

    public init(lockDelay: TimeInterval = 10, absenceGrace: TimeInterval = 2.5,
                confirmFrames: Int = 2, maxTickGap: TimeInterval = 3) {
        self.lockDelay = lockDelay
        self.absenceGrace = absenceGrace
        self.confirmFrames = confirmFrames
        self.maxTickGap = maxTickGap
    }
}

public enum PresenceStatus: Equatable, Sendable {
    case present
    case absent(remaining: TimeInterval)
    case lockDue
}

/// Machine à états « le propriétaire est-il là ? ».
///
/// Règle centrale : seul un visage reconnu comme celui du propriétaire remet le compteur à zéro.
/// Une image sans visage, une image avec un visage inconnu ou une image manquante sont
/// strictement équivalentes : elles ne font rien, le temps continue de s'écouler.
public struct PresenceEngine: Sendable {
    public var config: PresenceConfig
    public private(set) var lastOwnerSeen: TimeInterval
    private var lastTick: TimeInterval
    private var consecutiveMatches = 0
    private var lastMatch: TimeInterval = -.infinity
    private var inAbsence = false
    /// Deux reconnaissances ne sont « consécutives » que si elles sont rapprochées.
    private let matchWindow: TimeInterval = 1.5

    public init(config: PresenceConfig = .init(), now: TimeInterval) {
        self.config = config
        self.lastOwnerSeen = now
        self.lastTick = now
    }

    /// Repart de zéro (démarrage, reprise après veille/déverrouillage, retour de la caméra).
    public mutating func reset(now: TimeInterval) {
        lastOwnerSeen = now
        lastTick = now
        consecutiveMatches = 0
        lastMatch = -.infinity
        inAbsence = false
    }

    /// À appeler pour chaque image analysée. `ownerRecognized` vaut `true` uniquement si
    /// au moins un visage de l'image correspond au propriétaire — peu importe les autres visages.
    public mutating func ingest(ownerRecognized: Bool, now: TimeInterval) {
        guard ownerRecognized else {
            consecutiveMatches = 0
            return
        }
        consecutiveMatches = (now - lastMatch <= matchWindow) ? consecutiveMatches + 1 : 1
        lastMatch = now
        if !inAbsence || consecutiveMatches >= config.confirmFrames {
            lastOwnerSeen = now
            inAbsence = false
        }
    }

    /// À appeler régulièrement (plusieurs fois par seconde).
    public mutating func tick(now: TimeInterval) -> PresenceStatus {
        if now - lastTick > config.maxTickGap || now < lastTick {
            reset(now: now)
            return .present
        }
        lastTick = now
        let elapsed = now - lastOwnerSeen
        if elapsed >= config.lockDelay {
            inAbsence = true
            // Une reconnaissance en attente de confirmation retient le verrouillage
            // le temps d'une image ; un visage inconnu remet ce compteur à zéro et ne retient rien.
            let pending = consecutiveMatches > 0 && now - lastMatch <= matchWindow
            return pending ? .absent(remaining: 0) : .lockDue
        }
        if elapsed >= min(config.absenceGrace, config.lockDelay) {
            inAbsence = true
            return .absent(remaining: config.lockDelay - elapsed)
        }
        return .present
    }
}
