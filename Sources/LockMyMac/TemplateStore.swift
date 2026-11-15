import Foundation
import LockMyMacCore

/// Stockage local des empreintes du propriétaire : un fichier JSON lisible par lui seul.
/// Il ne contient que des vecteurs numériques — aucune photo n'est jamais enregistrée.
enum TemplateStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lockMyMac", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("empreintes-visage.json") }

    static func load() -> FaceTemplates? {
        guard let data = try? Data(contentsOf: fileURL),
              let templates = try? JSONDecoder().decode(FaceTemplates.self, from: data),
              templates.modelID == FaceRecognizer.modelID, !templates.embeddings.isEmpty else { return nil }
        return templates
    }

    static func save(_ templates: FaceTemplates) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(templates).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
