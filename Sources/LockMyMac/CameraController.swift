import AVFoundation

struct CameraInfo: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Pilote la caméra. Aucune image n'est écrite sur disque : les images passent en mémoire,
/// la plupart sont jetées (limitation de fréquence), les autres sont analysées puis libérées.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Appelé sur le fil principal quand la caméra tombe en panne ou ne peut pas démarrer.
    var onError: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "lockmymac.camera.session")
    private let videoQueue = DispatchQueue(label: "lockmymac.camera.video", qos: .utility)
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var handler: ((CVPixelBuffer) -> Void)?
    private var interval: TimeInterval = 1
    private var lastAnalysis: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var currentDeviceID: String?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "erreur inconnue"
            self?.onError?("Erreur de la caméra : \(err)")
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            self.lock.lock(); let current = self.currentDeviceID; self.lock.unlock()
            if device.uniqueID == current { self.onError?("La caméra a été déconnectée.") }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static func availableCameras() -> [CameraInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func device(id: String?) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified).devices
        if let id, !id.isEmpty { return devices.first { $0.uniqueID == id } }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    /// Intervalle minimal entre deux analyses.
    func setAnalysisInterval(_ value: TimeInterval) {
        lock.lock(); interval = value; lock.unlock()
    }

    /// Instant (uptime) de la dernière image reçue de la caméra, analysée ou non.
    var lastFrameTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }; return lastFrame
    }

    /// Démarre la capture. `handler` est appelé sur une file d'arrière-plan, au plus une fois par intervalle.
    func start(deviceID: String?, lowPower: Bool, handler: @escaping (CVPixelBuffer) -> Void) {
        lock.lock()
        self.handler = handler
        lastAnalysis = 0
        lastFrame = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        sessionQueue.async { [self] in
            guard let device = Self.device(id: deviceID) else {
                fail(deviceID?.isEmpty == false ? "La caméra choisie est introuvable." : "Aucune caméra détectée.")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    fail("La caméra « \(device.localizedName) » ne peut pas être utilisée.")
                    return
                }
                session.addInput(input)
                if session.outputs.isEmpty {
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: videoQueue)
                    if session.canAddOutput(output) { session.addOutput(output) }
                }
                session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
                session.commitConfiguration()
                if lowPower { Self.reduceFrameRate(of: device) }
                lock.lock(); currentDeviceID = device.uniqueID; lock.unlock()
                session.startRunning()
                if !session.isRunning { fail("La caméra n'a pas pu démarrer.") }
            } catch {
                fail("Caméra inaccessible : \(error.localizedDescription)")
            }
        }
    }

    /// Arrête la capture et libère la caméra (le voyant s'éteint).
    func stop() {
        lock.lock(); handler = nil; lock.unlock()
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
            lock.lock(); currentDeviceID = nil; lock.unlock()
        }
    }

    /// Demande au capteur la cadence la plus basse qu'il sait fournir (≥ 5 images/s) :
    /// moins d'images produites, moins d'énergie, sans effet sur la fréquence d'analyse.
    private static func reduceFrameRate(of device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let slowest = ranges.min(by: { $0.minFrameRate < $1.minFrameRate }) else { return }
        // Seules des durées annoncées par le capteur sont utilisées (une valeur hors plage lève une exception).
        let duration: CMTime
        if slowest.minFrameRate <= 5, slowest.maxFrameRate >= 5 {
            duration = CMTime(value: 1, timescale: 5)
        } else if slowest.minFrameRate < slowest.maxFrameRate || ranges.count > 1 {
            duration = slowest.maxFrameDuration
        } else {
            return
        }
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastFrame = now
        let due = now - lastAnalysis >= interval
        if due { lastAnalysis = now }
        let handler = self.handler
        lock.unlock()
        guard due, let handler, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer)
    }
}
