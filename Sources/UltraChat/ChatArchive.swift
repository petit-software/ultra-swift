import Foundation

/// Conversations, as files under the project.
///
/// `.ultra/chats/<id>.json`, one per conversation, beside the todo list and the context
/// list: a chat about a project belongs to the project, the same way its notes do, and an
/// agent in the next pane can read it.
public struct ChatArchive: Sendable {
    public let directory: URL

    public init(root: URL) {
        directory = root.appendingPathComponent(".ultra/chats", isDirectory: true)
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Every conversation, newest first. A file that cannot be read is skipped rather than
    /// failing the list; it is still on disk for whoever wants to look.
    public func load() -> [ChatConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.decoder
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatConversation? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ChatConversation.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: UUID) -> ChatConversation? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder.decode(ChatConversation.self, from: data)
    }

    public func save(_ conversation: ChatConversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(conversation).write(to: url(for: conversation.id), options: .atomic)
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
