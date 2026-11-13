import XCTest
@testable import LockMyMacCore

/// Rejoue les scénarios du cahier des charges sur le moteur de décision.
/// Une « image » = ce que la reconnaissance a conclu : propriétaire reconnu ou non.
final class PresenceEngineTests: XCTestCase {
    enum Frame { case owner, stranger, ownerAndStranger, empty, dropped }

    /// Simule `seconds` secondes : tick à 4 Hz, une image par seconde quand présent,
    /// ~3 par seconde pendant l'absence (comme l'app). Renvoie l'instant du verrouillage s'il a lieu.
    @discardableResult
    func run(_ engine: inout PresenceEngine, from start: TimeInterval, seconds: TimeInterval,
             frame: Frame, threshold: Float = 0.55) -> TimeInterval? {
        var t = start, nextFrame = start
        while t < start + seconds {
            if t >= nextFrame, frame != .dropped {
                let sims: [Float]
                switch frame {
                case .owner: sims = [0.8]
                case .stranger: sims = [0.2]
                case .ownerAndStranger: sims = [0.15, 0.78]
                case .empty, .dropped: sims = []
                }
                engine.ingest(ownerRecognized: FaceMatcher.ownerPresent(similarities: sims, threshold: threshold), now: t)
            }
            let status = engine.tick(now: t)
            if status == .lockDue { return t }
            if t >= nextFrame { nextFrame = t + (status == .present ? 1.0 : 0.3) }
            t += 0.25
        }
        return nil
    }

    func testJeParsSeul() {
        var e = PresenceEngine(now: 0)
        XCTAssertNil(run(&e, from: 0, seconds: 30, frame: .owner))
        let lock = run(&e, from: 30, seconds: 30, frame: .empty)
        XCTAssertNotNil(lock)
        // Dernière reconnaissance à t=29 → verrouillage 10 s plus tard.
        XCTAssertEqual(lock!, 39, accuracy: 0.3)
    }

    func testJeParsEtQuelquUnReste() {
        var e = PresenceEngine(now: 0)
        run(&e, from: 0, seconds: 30, frame: .owner)
        let lock = run(&e, from: 30, seconds: 30, frame: .stranger)
        XCTAssertNotNil(lock, "un visage inconnu ne doit jamais retenir le verrouillage")
        XCTAssertEqual(lock!, 39, accuracy: 0.3)
    }

    func testQuelquUnPasseDerriereMoi() {
        var e = PresenceEngine(now: 0)
        XCTAssertNil(run(&e, from: 0, seconds: 120, frame: .ownerAndStranger))
        XCTAssertEqual(e.tick(now: 120), .present)
    }

    func testRotationBreveDeLaTete() {
        var e = PresenceEngine(now: 0)
        run(&e, from: 0, seconds: 20, frame: .owner)
        // 4 s sans reconnaissance (tête tournée), puis retour.
        XCTAssertNil(run(&e, from: 20, seconds: 4, frame: .empty))
        if case .absent(let r) = e.tick(now: 24) { XCTAssertGreaterThan(r, 4) } else { XCTFail("absence attendue") }
        XCTAssertNil(run(&e, from: 24.25, seconds: 30, frame: .owner))
        XCTAssertEqual(e.tick(now: 54.25), .present)
    }

    func testImageRateeIsolee() {
        var e = PresenceEngine(now: 0)
        run(&e, from: 0, seconds: 10, frame: .owner)
        XCTAssertNil(run(&e, from: 10, seconds: 1, frame: .dropped))
        XCTAssertEqual(e.tick(now: 11), .present, "une image ratée ne doit même pas déclencher l'affichage d'absence")
        XCTAssertNil(run(&e, from: 11.25, seconds: 20, frame: .owner))
    }

    func testJeReviensAvantExpiration() {
        var e = PresenceEngine(now: 0)
        run(&e, from: 0, seconds: 10, frame: .owner)
        XCTAssertNil(run(&e, from: 10, seconds: 8, frame: .empty))   // dernière vue à t=9 → 9 s d'absence
        XCTAssertNil(run(&e, from: 18, seconds: 30, frame: .owner), "le retour doit annuler le compte à rebours")
        XCTAssertEqual(e.tick(now: 48), .present)
    }

    func testRetourALaToutDerniereSeconde() {
        var e = PresenceEngine(now: 0)
        e.ingest(ownerRecognized: true, now: 0)
        _ = e.tick(now: 2); _ = e.tick(now: 4); _ = e.tick(now: 6); _ = e.tick(now: 8)
        // Première image reconnue juste avant l'échéance : en attente de confirmation.
        e.ingest(ownerRecognized: true, now: 9.9)
        XCTAssertEqual(e.tick(now: 10.1), .absent(remaining: 0), "une reconnaissance en attente retient le verrouillage")
        e.ingest(ownerRecognized: true, now: 10.2)
        XCTAssertEqual(e.tick(now: 10.3), .present)
    }

    func testInconnuNeRetientPasALEcheance() {
        var e = PresenceEngine(now: 0)
        _ = e.tick(now: 2); _ = e.tick(now: 4); _ = e.tick(now: 6); _ = e.tick(now: 8)
        e.ingest(ownerRecognized: true, now: 9.9)    // fausse acceptation isolée…
        e.ingest(ownerRecognized: false, now: 10.0)  // …démentie par l'image suivante
        XCTAssertEqual(e.tick(now: 10.1), .lockDue)
    }

    func testFausseAcceptationIsoleeNAnnulePasLeCompteARebours() {
        var e = PresenceEngine(now: 0)
        _ = e.tick(now: 2); _ = e.tick(now: 4)       // absence déclarée
        e.ingest(ownerRecognized: true, now: 5)      // une seule image « reconnue »
        e.ingest(ownerRecognized: false, now: 5.3)
        guard case .absent(let r) = e.tick(now: 6) else { return XCTFail("absence attendue") }
        XCTAssertEqual(r, 4, accuracy: 0.01, "le compteur ne doit pas avoir été remis à zéro")
    }

    func testVeillePuisReveil() {
        var e = PresenceEngine(now: 0)
        run(&e, from: 0, seconds: 10, frame: .owner)
        // Le Mac dort une heure sans que l'app soit prévenue : pas de verrouillage aveugle au réveil…
        XCTAssertEqual(e.tick(now: 3610), .present)
        // …mais si je ne suis pas là, le délai normal s'applique à partir du réveil.
        let lock = run(&e, from: 3610.25, seconds: 30, frame: .empty)
        XCTAssertNotNil(lock)
        XCTAssertEqual(lock!, 3620, accuracy: 0.3)
    }

    func testDelaiReglable() {
        var e = PresenceEngine(config: .init(lockDelay: 30), now: 0)
        XCTAssertNil(run(&e, from: 0, seconds: 29, frame: .empty))
        XCTAssertNotNil(run(&e, from: 29, seconds: 5, frame: .empty))
    }

    func testAppariement() {
        let a = FaceMatcher.normalized([1, 2, 3]), b = FaceMatcher.normalized([-3, 0, 1])
        XCTAssertEqual(FaceMatcher.cosine(a, a), 1, accuracy: 1e-5)
        XCTAssertEqual(FaceMatcher.cosine(a, b), 0, accuracy: 1e-5)
        XCTAssertEqual(FaceMatcher.bestSimilarity(a, in: [b, a]), 1, accuracy: 1e-5)
        XCTAssertEqual(FaceMatcher.bestSimilarity(a, in: []), -1)
        XCTAssertFalse(FaceMatcher.ownerPresent(similarities: [], threshold: 0.55))
        XCTAssertFalse(FaceMatcher.ownerPresent(similarities: [0.54, 0.1], threshold: 0.55))
        XCTAssertTrue(FaceMatcher.ownerPresent(similarities: [0.1, 0.56], threshold: 0.55))
    }
}
