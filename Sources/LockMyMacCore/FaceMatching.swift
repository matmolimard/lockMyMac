import Foundation

/// Empreintes du propriétaire. Ce sont des vecteurs numériques, jamais des images.
public struct FaceTemplates: Codable, Equatable, Sendable {
    public var version = 1
    public var modelID: String
    public var createdAt: Date
    public var embeddings: [[Float]]

    public init(modelID: String, createdAt: Date = Date(), embeddings: [[Float]]) {
        self.modelID = modelID
        self.createdAt = createdAt
        self.embeddings = embeddings
    }
}

public enum FaceMatcher {
    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Similarité cosinus entre deux vecteurs (−1…1).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : -1
    }

    /// Meilleure similarité entre un visage et les empreintes enregistrées.
    public static func bestSimilarity(_ embedding: [Float], in templates: [[Float]]) -> Float {
        templates.map { cosine(embedding, $0) }.max() ?? -1
    }

    /// Le propriétaire est présent si au moins un visage dépasse le seuil.
    /// Les visages sous le seuil sont ignorés : ils ne valident ni n'invalident rien.
    public static func ownerPresent(similarities: [Float], threshold: Float) -> Bool {
        similarities.contains { $0 >= threshold }
    }
}
