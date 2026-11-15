import CoreImage
import Foundation
import LockMyMacCore

/// `lockMyMac --compare a.jpg b.jpg [c.jpg…]` : affiche la similarité entre les visages de plusieurs photos.
/// Sert à vérifier la chaîne de reconnaissance sans caméra.
enum CompareCommand {
    static func run(_ paths: [String]) -> Int32 {
        guard paths.count >= 2 else {
            print("usage : lockMyMac --compare image1 image2 [image3 …]")
            return 2
        }
        do {
            let recognizer = try FaceRecognizer()
            var embeddings: [(String, [Float])] = []
            for path in paths {
                guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
                    print("illisible : \(path)"); return 1
                }
                let faces = recognizer.analyze(image: image)
                guard let embedding = faces.first?.embedding else {
                    print("aucun visage exploitable : \(path) (\(faces.count) détecté(s))"); return 1
                }
                embeddings.append(((path as NSString).lastPathComponent, embedding))
            }
            for i in 0..<embeddings.count {
                for j in (i + 1)..<embeddings.count {
                    let s = FaceMatcher.cosine(embeddings[i].1, embeddings[j].1)
                    print(String(format: "%.3f  %@  ↔  %@", s, embeddings[i].0, embeddings[j].0))
                }
            }
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }
}
