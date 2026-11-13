import AppKit
import AVFoundation
import ServiceManagement
@preconcurrency import UserNotifications
import LockMyMacCore

/// Un visage tel qu'affiché en mode test.
struct LiveFace: Identifiable {
    let id: Int
    let box: CGRect
    /// Similarité avec le propriétaire ; `nil` si le visage est trop petit pour être identifié.
    let similarity: Float?
    let isOwner: Bool
}

enum MonitorState: Equatable {
    case modelMissing(String)
    case notEnrolled
    case enrolling
    case paused
    /// Suspendue parce que le Mac est sur un réseau Wi-Fi marqué « sans surveillance ».
    case exemptNetwork(String)
    case starting
    case recognized
    case absent(secondsLeft: Int)
    case cameraUnavailable(String)
    case sessionLocked
}

/// Chef d'orchestre : décide quand la caméra tourne, alimente le moteur de décision, verrouille.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: État publié
    @Published private(set) var state: MonitorState = .starting
    @Published private(set) var isEnrolled = false
    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var testMode = false
    /// En mode test : le verrouillage aurait eu lieu.
    @Published private(set) var testLockFired = false
    @Published private(set) var liveFaces: [LiveFace] = []
    @Published private(set) var videoAspect: CGFloat = 4.0 / 3.0
    @Published private(set) var launchAtLogin = false
    @Published var lastError: String?
    @Published private(set) var enrollment = EnrollmentProgress()

    // MARK: Réglages (persistés)
    @Published var monitoringEnabled: Bool { didSet { defaults.set(monitoringEnabled, forKey: "monitoringEnabled"); evaluate() } }
    @Published var lockDelay: Double { didSet { defaults.set(lockDelay, forKey: "lockDelay"); engine?.config.lockDelay = lockDelay } }
    /// 0 = surveillance continue. Sinon, secondes entre deux vérifications brèves (caméra éteinte entre-temps).
    @Published var checkInterval: Double {
        didSet {
            defaults.set(checkInterval, forKey: "checkInterval")
            if checkInterval != oldValue, activity == .monitoring { apply(.idle); evaluate() }
        }
    }
    @Published var threshold: Double { didSet { defaults.set(threshold, forKey: "threshold") } }
    @Published var cameraID: String { didSet { defaults.set(cameraID, forKey: "cameraID"); if cameraID != oldValue { restartCamera() } } }
    /// Réseaux Wi-Fi (domicile…) sur lesquels la surveillance se suspend d'elle-même.
    @Published var exemptNetworks: [String] { didSet { defaults.set(exemptNetworks, forKey: "exemptNetworks"); evaluate() } }
    @Published private(set) var currentNetwork: String?
    @Published var lockOnCameraFailure: Bool { didSet { defaults.set(lockOnCameraFailure, forKey: "lockOnCameraFailure") } }

    static let defaultThreshold = 0.65

    // MARK: Interne
    let camera = CameraController()
    let windows = WindowManager()
    let network = NetworkGate()
    private var pendingExemption = false
    private let defaults = UserDefaults.standard
    private var recognizer: FaceRecognizer?
    private var templates: FaceTemplates?
    private var engine: PresenceEngine?
    private var sessionObserver: SessionObserver?
    private enum Activity { case idle, monitoring, enrolling }
    private var activity: Activity = .idle
    private var cameraRunning = false
    private var cameraLowPower = true
    private var cameraProblem: String?
    private var cameraProblemSince: TimeInterval = 0
    private var lastCameraRetry: TimeInterval = 0
    private var generation = 0
    private var tickTimer: Timer?
    private var housekeepingTimer: Timer?
    private var systemSleeping = false
    private var lockInProgress = false
    private var napToken: NSObjectProtocol?
    private var enroller = Enroller()
    // Mode périodique
    static let missesBeforeLock = 2
    private var periodic: Bool { checkInterval > 0 && !testMode }
    private var burstActive = false
    private var burstStart: TimeInterval = 0
    private var burstFirstFrame: TimeInterval?
    private var burstRecognized = false
    private var nextCheckAt: TimeInterval = 0
    private var misses = 0
    /// Vrai depuis la première panne caméra jusqu'à la prochaine image reçue (évite de re-notifier à chaque essai).
    private var problemOngoing = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init() {
        defaults.register(defaults: ["lockDelay": 10.0, "threshold": Self.defaultThreshold])
        monitoringEnabled = defaults.bool(forKey: "monitoringEnabled")
        lockDelay = defaults.double(forKey: "lockDelay")
        threshold = defaults.double(forKey: "threshold")
        checkInterval = defaults.double(forKey: "checkInterval")
        cameraID = defaults.string(forKey: "cameraID") ?? ""
        exemptNetworks = defaults.stringArray(forKey: "exemptNetworks") ?? []
        lockOnCameraFailure = defaults.bool(forKey: "lockOnCameraFailure")
    }

    func start() {
        do { recognizer = try FaceRecognizer() } catch { state = .modelMissing(error.localizedDescription) }
        templates = TemplateStore.load()
        isEnrolled = templates != nil
        refreshCameras()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        camera.onError = { [weak self] message in
            Task { @MainActor in self?.cameraFailed(message) }
        }
        sessionObserver = SessionObserver { [weak self] event in
            Task { @MainActor in self?.sessionEvent(event) }
        }
        network.onChange = { [weak self] in self?.networkChanged() }
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshCameras() }
            }
        }
        // Filet de sécurité : si une notification système se perd, on se recale en quelques secondes.
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
        if recognizer != nil, !isEnrolled { showEnrollment() }
    }

    // MARK: Décision « la caméra doit-elle tourner ? »

    private var sessionUsable: Bool {
        !systemSleeping && !lockInProgress && !SessionLocker.isScreenLocked
            && !SessionLocker.isDisplayAsleep && SessionLocker.isOnConsole
    }

    func evaluate() {
        let ssid = network.currentSSID
        if ssid != currentNetwork { currentNetwork = ssid }
        guard recognizer != nil else { return apply(.idle) }
        let wanted: Activity
        if enrollment.phase == .capturing {
            wanted = sessionUsable ? .enrolling : .idle
            setState(.enrolling)
        } else if !isEnrolled {
            wanted = .idle
            setState(.notEnrolled)
        } else if !(monitoringEnabled || testMode) {
            wanted = .idle
            setState(.paused)
        } else if !testMode, let ssid, exemptNetworks.contains(ssid) {
            // Seul un réseau explicitement listé suspend : réseau inconnu, Ethernet ou nom illisible → on surveille.
            wanted = .idle
            setState(.exemptNetwork(ssid))
        } else if !sessionUsable {
            wanted = .idle
            setState(.sessionLocked)
        } else {
            wanted = .monitoring
        }
        apply(wanted)
    }

    private func apply(_ wanted: Activity) {
        let lowPower = wanted == .monitoring && !testMode
        if wanted == activity, wanted == .idle || lowPower == cameraLowPower { return }
        stopCamera()
        activity = wanted
        cameraLowPower = lowPower
        engine = nil
        cameraProblem = nil
        problemOngoing = false
        testLockFired = false
        liveFaces = []
        if wanted == .idle {
            tickTimer?.invalidate(); tickTimer = nil
            if let napToken { ProcessInfo.processInfo.endActivity(napToken) }
            napToken = nil
            return
        }
        if wanted == .monitoring { setState(.starting) }
        if tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        if napToken == nil {
            // Empêche App Nap de geler nos minuteries, sans empêcher la mise en veille du Mac.
            napToken = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Surveillance de présence")
        }
        if wanted == .monitoring, periodic {
            burstActive = false
            misses = 0
            nextCheckAt = now   // première vérification tout de suite
        } else {
            startCamera()
        }
    }

    private func setState(_ new: MonitorState) {
        if state != new { state = new }
    }

    // MARK: Caméra

    private func startCamera() {
        guard let recognizer, activity != .idle else { return }
        lastCameraRetry = now
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            Self.requestCameraAccess { [weak self] in self?.startCamera() }
            return
        default:
            cameraFailed("Accès à la caméra refusé. Autorisez lockMyMac dans Réglages Système › Confidentialité et sécurité › Caméra.")
            return
        }
        generation += 1
        cameraRunning = true
        camera.setAnalysisInterval(activity == .enrolling || testMode ? 0.2 : 1.0)
        camera.start(deviceID: cameraID, lowPower: cameraLowPower,
                     handler: Self.frameHandler(recognizer: recognizer, generation: generation))
    }

    // Ces fermetures s'exécutent hors du fil principal : elles sont construites dans un contexte
    // non isolé pour ne pas hériter de @MainActor.
    private nonisolated static func requestCameraAccess(then: @escaping @MainActor () -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in then() }
        }
    }

    private nonisolated static func frameHandler(recognizer: FaceRecognizer, generation: Int) -> (CVPixelBuffer) -> Void {
        { pixelBuffer in
            // File d'arrière-plan : détection + empreintes. L'image n'est conservée nulle part.
            let faces = recognizer.analyze(pixelBuffer: pixelBuffer)
            let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
            Task { @MainActor in AppModel.shared.handleFrame(faces, aspect: aspect, generation: generation) }
        }
    }

    private func stopCamera() {
        generation += 1
        if cameraRunning { camera.stop() }
        cameraRunning = false
    }

    private func restartCamera() {
        guard activity != .idle else { return }
        stopCamera()
        engine = nil
        cameraProblem = nil
        startCamera()
    }

    private func cameraFailed(_ message: String) {
        guard activity != .idle else { return }
        stopCamera()   // on relâche la caméra ; nouvel essai périodique dans tick()
        engine = nil
        liveFaces = []
        if !problemOngoing {
            problemOngoing = true
            cameraProblemSince = now
            if activity == .monitoring {
                notify("Protection interrompue", "Caméra indisponible : le verrouillage automatique ne fonctionne plus. \(message)")
            }
        }
        cameraProblem = message
        if activity == .monitoring { setState(.cameraUnavailable(message)) }
        if activity == .enrolling { enrollment.hint = message }
    }

    func refreshCameras() {
        let list = CameraController.availableCameras()
        if list != cameras { cameras = list }
    }

    // MARK: Boucle principale

    private func handleFrame(_ faces: [DetectedFace], aspect: CGFloat, generation gen: Int) {
        guard gen == generation else { return }   // résultat d'une capture déjà arrêtée
        if abs(aspect - videoAspect) > 0.01 { videoAspect = aspect }
        cameraProblem = nil
        problemOngoing = false
        switch activity {
        case .idle:
            break
        case .enrolling:
            if let finished = enroller.ingest(faces, now: now, progress: &enrollment) { finishEnrollment(finished) }
        case .monitoring:
            guard let templates else { return }
            let scored = faces.map { face in face.embedding.map { FaceMatcher.bestSimilarity($0, in: templates.embeddings) } }
            let limit = Float(threshold)
            let owner = FaceMatcher.ownerPresent(similarities: scored.compactMap { $0 }, threshold: limit)
            if periodic {
                guard burstActive else { return stopCamera() }   // image arrivée hors vérification : on éteint
                if burstFirstFrame == nil { burstFirstFrame = now }
                if owner { burstRecognized = true }
                return
            }
            if engine == nil { engine = PresenceEngine(config: .init(lockDelay: lockDelay), now: now) }
            engine?.ingest(ownerRecognized: owner, now: now)
            if testMode {
                liveFaces = zip(faces, scored).enumerated().map { index, pair in
                    LiveFace(id: index, box: pair.0.box, similarity: pair.1, isOwner: (pair.1 ?? -1) >= limit)
                }
            }
        }
    }

    private func tick() {
        guard activity == .monitoring else {
            if activity == .enrolling, cameraProblem != nil, now - lastCameraRetry > 5 { startCamera() }
            return
        }
        if periodic { return tickPeriodic() }
        if let problem = cameraProblem {
            setState(.cameraUnavailable(problem))
            if lockOnCameraFailure, !testMode, now - cameraProblemSince >= lockDelay {
                performLock()
            } else if now - lastCameraRetry > 5 {
                startCamera()
            }
            return
        }
        if cameraRunning, now - camera.lastFrameTime > 5 {
            cameraFailed("La caméra ne fournit plus d'image (utilisée ailleurs, capot fermé ou débranchée ?).")
            return
        }
        guard engine != nil, let status = engine?.tick(now: now) else { return setState(.starting) }
        switch status {
        case .present:
            testLockFired = false
            camera.setAnalysisInterval(testMode ? 0.2 : 1.0)
            setState(.recognized)
        case .absent(let remaining):
            camera.setAnalysisInterval(testMode ? 0.2 : 0.3)   // on regarde plus souvent pour ne pas rater un retour
            setState(.absent(secondsLeft: Int(remaining.rounded(.up))))
        case .lockDue:
            setState(.absent(secondsLeft: 0))
            if testMode { testLockFired = true } else { performLock() }
        }
    }

    /// Mode périodique : la caméra ne s'allume que quelques secondes à chaque vérification.
    /// Un visage inconnu ou l'absence de visage comptent pareil : vérification manquée.
    private func tickPeriodic() {
        let t = now
        if burstActive {
            if cameraProblem != nil {
                burstActive = false
                nextCheckAt = t + min(checkInterval, 15)
            } else if burstRecognized {
                endBurst()
                misses = 0
                nextCheckAt = t + checkInterval
                setState(.recognized)
            } else if let first = burstFirstFrame {
                // On laisse 3 s à la caméra (exposition, mise au point) avant de conclure à l'absence.
                guard t - first >= 3 else { return }
                endBurst()
                misses += 1
                if misses >= Self.missesBeforeLock {
                    performLock()
                } else {
                    nextCheckAt = t + checkInterval
                    setState(.absent(secondsLeft: Int(checkInterval)))
                }
            } else if t - burstStart > 6 {
                cameraFailed("La caméra ne fournit pas d'image (utilisée ailleurs, capot fermé ou débranchée ?).")
            }
            return
        }
        if let problem = cameraProblem {
            setState(.cameraUnavailable(problem))
            if lockOnCameraFailure, t - cameraProblemSince >= checkInterval * Double(Self.missesBeforeLock) {
                return performLock()
            }
        } else if misses > 0 {
            setState(.absent(secondsLeft: max(0, Int((nextCheckAt - t).rounded(.up)))))
        }
        guard t >= nextCheckAt else { return }
        burstActive = true
        burstStart = t
        burstFirstFrame = nil
        burstRecognized = false
        cameraProblem = nil   // nouvel essai ; `problemOngoing` garde la mémoire de la panne
        startCamera()
        camera.setAnalysisInterval(0.3)
    }

    private func endBurst() {
        burstActive = false
        stopCamera()
    }

    // MARK: Verrouillage et session

    private func performLock() {
        guard !lockInProgress else { return }
        lockInProgress = true
        evaluate()   // libère la caméra immédiatement
        SessionLocker.lockNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.lockInProgress = false
            if !SessionLocker.isScreenLocked, !SessionLocker.isDisplayAsleep {
                self.lastError = "Le verrouillage de la session a échoué."
                self.notify("Verrouillage impossible", "lockMyMac n'a pas réussi à verrouiller la session. Verrouillez avec ⌃⌘Q.")
            }
            self.evaluate()
        }
    }

    func lockNow() {
        SessionLocker.lockNow()
    }

    private func sessionEvent(_ event: SessionObserver.Event) {
        switch event {
        case .willSleep: systemSleeping = true
        case .didWake: systemSleeping = false
        case .changed: break
        }
        evaluate()
    }

    // MARK: Mode test

    func showTest() {
        guard isEnrolled else { return showEnrollment() }
        testMode = true
        evaluate()
        windows.show(id: "test", title: "lockMyMac — Mode test", onClose: { [weak self] in
            self?.testMode = false
            self?.evaluate()
        }) { TestView(model: self) }
    }

    // MARK: Enregistrement du visage

    func showEnrollment() {
        windows.close(id: "test")
        enrollment = EnrollmentProgress()
        windows.show(id: "enroll", title: "lockMyMac — Enregistrement du visage", onClose: { [weak self] in
            guard let self else { return }
            if self.enrollment.phase == .capturing { self.enrollment = EnrollmentProgress() }
            self.evaluate()
        }) { EnrollmentView(model: self) }
    }

    func beginEnrollmentCapture() {
        enroller = Enroller()
        enrollment = EnrollmentProgress()
        enrollment.phase = .capturing
        evaluate()
    }

    func captureEnrollmentManually() {
        enroller.forceNext = true
    }

    private func finishEnrollment(_ embeddings: [[Float]]) {
        let new = FaceTemplates(modelID: FaceRecognizer.modelID, embeddings: embeddings)
        do {
            try TemplateStore.save(new)
            templates = new
            isEnrolled = true
            enrollment.phase = .done
        } catch {
            enrollment.phase = .intro
            lastError = "Impossible d'enregistrer les empreintes : \(error.localizedDescription)"
        }
        evaluate()
    }

    func deleteFace() {
        let alert = NSAlert()
        alert.messageText = "Supprimer mon visage ?"
        alert.informativeText = "Les empreintes enregistrées seront effacées de ce Mac et la surveillance s'arrêtera."
        alert.addButton(withTitle: "Supprimer")
        alert.addButton(withTitle: "Annuler")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        windows.close(id: "test")
        TemplateStore.delete()
        templates = nil
        isEnrolled = false
        monitoringEnabled = false
    }

    // MARK: Réseaux sans surveillance

    var locationDenied: Bool { network.isDenied }

    /// Ajoute le réseau Wi-Fi actuel à la liste, en demandant d'abord le droit de lire son nom.
    func exemptCurrentNetwork() {
        if network.isDenied {
            lastError = "Pour lire le nom du Wi-Fi, autorisez lockMyMac dans Réglages Système › Confidentialité et sécurité › Service de localisation."
            return
        }
        guard network.isAuthorized else {
            pendingExemption = true
            NSApp.activate(ignoringOtherApps: true)
            network.requestAccess()
            return
        }
        guard let ssid = network.currentSSID else {
            lastError = "Aucun réseau Wi-Fi connecté : impossible de reconnaître ce lieu."
            return
        }
        if !exemptNetworks.contains(ssid) { exemptNetworks.append(ssid) }
    }

    func setExempt(_ ssid: String, _ exempt: Bool) {
        if exempt {
            if !exemptNetworks.contains(ssid) { exemptNetworks.append(ssid) }
        } else {
            exemptNetworks.removeAll { $0 == ssid }
        }
    }

    private func networkChanged() {
        if pendingExemption, network.isAuthorized || network.isDenied {
            pendingExemption = false
            exemptCurrentNetwork()
        }
        evaluate()
    }

    // MARK: Divers

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Lancement au démarrage : \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showSettings() {
        windows.show(id: "settings", title: "Réglages de lockMyMac", onClose: {}) { SettingsView(model: self) }
    }

    private nonisolated func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: title, content: content, trigger: nil))
        }
    }

    // MARK: Textes pour l'interface

    var statusLine: String {
        let base: String
        switch state {
        case .modelMissing: base = "Modèle de reconnaissance manquant"
        case .notEnrolled: base = "Aucun visage enregistré"
        case .enrolling: base = "Enregistrement du visage en cours"
        case .paused: base = "Surveillance suspendue"
        case .exemptNetwork(let ssid): base = "Surveillance suspendue sur le réseau « \(ssid) »"
        case .starting: base = "Démarrage de la caméra…"
        case .recognized: base = periodic ? "Visage reconnu à la dernière vérification" : "Visage reconnu"
        case .absent(let s):
            base = testLockFired ? "Absence — verrouillage simulé"
                : periodic ? "Non reconnu — nouvelle vérification dans \(s) s, puis verrouillage"
                : "Absence en cours — verrouillage dans \(s) s"
        case .cameraUnavailable: base = "Caméra indisponible — protection interrompue"
        case .sessionLocked: base = "Session verrouillée ou écran en veille"
        }
        return testMode ? "Mode test · \(base)" : base
    }

    var symbolName: String {
        switch state {
        case .modelMissing, .cameraUnavailable: return "exclamationmark.triangle.fill"
        case .notEnrolled, .enrolling: return "person.crop.circle.badge.plus"
        case .paused: return "pause.circle"
        case .exemptNetwork: return "house.circle"
        case .starting: return "person.crop.circle.dashed"
        case .recognized: return "person.crop.circle.badge.checkmark"
        case .absent: return "person.crop.circle.badge.questionmark"
        case .sessionLocked: return "lock.circle"
        }
    }

    var menuBarText: String? {
        if case .absent(let s) = state { return testMode ? "test \(s)" : "\(s)" }
        return testMode ? "test" : nil
    }
}
