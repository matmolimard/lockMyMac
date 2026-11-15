import CoreImage
import CoreML
import Vision
import LockMyMacCore

struct DetectedFace {
    /// Cadre normalisé (0…1), origine en bas à gauche (convention Vision).
    var box: CGRect
    /// Angles en degrés, si Vision les fournit.
    var yaw: Double?
    var pitch: Double?
    /// Empreinte normalisée ; `nil` si le visage est trop petit pour être identifié.
    var embedding: [Float]?
}

enum RecognizerError: LocalizedError {
    case modelMissing
    var errorDescription: String? {
        "Modèle de reconnaissance introuvable (FaceEmbedding.mlmodelc). Lancez scripts/build_model.sh puis scripts/build_app.sh."
    }
}

/// Détection (Vision) puis identification (réseau FaceNet via Core ML), entièrement sur le Mac.
///
/// Vision sait *détecter* des visages mais n'expose aucune API publique pour dire *à qui* ils sont.
/// L'identité vient donc d'un modèle d'empreinte faciale : chaque visage devient un vecteur de
/// 512 nombres, comparé aux vecteurs enregistrés du propriétaire.
final class FaceRecognizer {
    static let modelID = "facenet-inception-resnet-v1-vggface2-160"
    /// En dessous de cette largeur (pixels), un visage est trop petit pour une empreinte fiable.
    static let minFacePixels: CGFloat = 56
    static let maxFaces = 4

    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var cropBuffer: CVPixelBuffer?

    init() throws {
        let candidates = [
            ProcessInfo.processInfo.environment["LOCKMYMAC_MODEL"].map { URL(fileURLWithPath: $0) },
            Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc"),
            URL(fileURLWithPath: "Models/FaceEmbedding.mlmodelc"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RecognizerError.modelMissing
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine quand il est disponible : rapide et sobre
        model = try MLModel(contentsOf: url, configuration: config)
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, 160, 160, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &cropBuffer)
    }

    func analyze(pixelBuffer: CVPixelBuffer) -> [DetectedFace] {
        analyze(image: CIImage(cvPixelBuffer: pixelBuffer))
    }

    /// Non réentrant : à appeler depuis une seule file à la fois.
    func analyze(image: CIImage) -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let extent = image.extent
        return results
            .sorted { $0.boundingBox.width > $1.boundingBox.width }
            .prefix(Self.maxFaces)
            .map { obs in
                let degrees = { (n: NSNumber?) in n.map { $0.doubleValue * 180 / .pi } }
                var face = DetectedFace(box: obs.boundingBox, yaw: degrees(obs.yaw), pitch: degrees(obs.pitch))
                if obs.boundingBox.width * extent.width >= Self.minFacePixels {
                    face.embedding = embedding(of: obs.boundingBox, in: image)
                }
                return face
            }
    }

    private func embedding(of box: CGRect, in image: CIImage) -> [Float]? {
        guard let cropBuffer else { return nil }
        let extent = image.extent
        let rect = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + box.minY * extent.height,
                          width: box.width * extent.width, height: box.height * extent.height)
        // Carré centré sur le visage, avec une marge, ramené à 160×160.
        let side = max(rect.width, rect.height) * 1.3
        let crop = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let scale = 160 / side
        let face = image.clampedToExtent().cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(face, to: cropBuffer, bounds: CGRect(x: 0, y: 0, width: 160, height: 160), colorSpace: colorSpace)
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: cropBuffer)]),
              let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let vector = (0..<array.count).map { array[$0].floatValue }
        return FaceMatcher.normalized(vector)
    }
}
