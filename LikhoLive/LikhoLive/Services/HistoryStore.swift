import Foundation

/// Persists and retrieves the last 20 transcript sessions locally on-device.
/// Storage: JSON file in Application Support.
final class HistoryStore {

    static let shared = HistoryStore()

    private let maxSessions = 20
    private(set) var sessions: [TranscriptSession] = []

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("LikhoLive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    // MARK: - Public API

    /// Appends a session and persists to disk.
    func save(session: TranscriptSession) {
        sessions.insert(session, at: 0)
        if sessions.count > maxSessions {
            sessions = Array(sessions.prefix(maxSessions))
        }
        persist()
    }

    /// Clears all stored history.
    func clearAll() {
        sessions = []
        try? FileManager.default.removeItem(at: storageURL)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TranscriptSession].self, from: data) else { return }
        sessions = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
