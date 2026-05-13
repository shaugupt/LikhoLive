import Foundation
import CryptoKit
import OSLog

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "ModelManager")

/// Manages whisper.cpp GGML models on disk: discover what's installed,
/// download new entries with progress + SHA-256 verification, atomic-rename
/// into place, and delete on demand.
///
/// Models live in `~/Library/Application Support/LikhoLive/models/`.
/// One download in flight at a time — calling `download(_:)` while another is
/// running cancels the previous and starts the new one.
@MainActor
final class ModelManager: NSObject, ObservableObject {

    static let shared = ModelManager()

    // MARK: - Public state (observable)

    /// Phases of the active download (if any).
    enum DownloadState: Equatable {
        case idle
        case downloading(id: String, bytesReceived: Int64, bytesExpected: Int64)
        case verifying(id: String)
    }

    /// Catalog ids that exist on disk. Refreshed on init, after every successful
    /// download, and after every delete.
    @Published private(set) var installedIDs: Set<String> = []

    /// Active download progress; `.idle` when nothing is happening.
    @Published private(set) var downloadState: DownloadState = .idle

    /// Last error message (e.g. checksum mismatch, network failure). Cleared
    /// when a new download starts.
    @Published private(set) var lastError: String?

    // MARK: - Paths

    /// `~/Library/Application Support/LikhoLive/models/`. `nonisolated let` so
    /// it's safely readable from URLSession delegate callbacks (which run off
    /// the main actor) without needing to hop.
    nonisolated let modelsDirectory: URL

    /// Filesystem URL where the (verified) GGML lives once installed.
    func localURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    /// Convenience: `localURL(for:)` if the id is installed; else `nil`.
    func installedLocalURL(for id: String) -> URL? {
        guard let model = WhisperModelCatalog.model(id: id),
              installedIDs.contains(id) else { return nil }
        return localURL(for: model)
    }

    func isInstalled(_ id: String) -> Bool { installedIDs.contains(id) }

    // MARK: - Internals

    private var session: URLSession!

    /// In-flight download bookkeeping. We store the continuation here so the
    /// URLSession delegate callbacks can resume it on success/error/cancel.
    private struct InFlight {
        let id: String
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<Void, Error>
    }
    private var inFlight: InFlight?

    private override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first!
        self.modelsDirectory = appSupport
            .appendingPathComponent("LikhoLive", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)

        super.init()

        try? FileManager.default.createDirectory(at: modelsDirectory,
                                                 withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        // Allow up to an hour for slow connections to pull a 1 GB model.
        cfg.timeoutIntervalForResource = 3600
        cfg.httpAdditionalHeaders = ["User-Agent": "LikhoLive/2.0 (whisper.cpp)"]
        cfg.allowsCellularAccess = true
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        cleanupOrphanStagingFiles()
        refreshInstalled()
    }

    // MARK: - Discovery

    /// Re-scans the models directory and updates `installedIDs`.
    /// O(catalog size); cheap to call.
    func refreshInstalled() {
        var found: Set<String> = []
        for model in WhisperModelCatalog.all {
            if FileManager.default.fileExists(atPath: localURL(for: model).path) {
                found.insert(model.id)
            }
        }
        installedIDs = found
        log.debug("Installed models: \(found.sorted().joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Download

    /// Downloads a catalog model: streams to a staging file, verifies SHA-256,
    /// atomic-renames into `<filename>`. Idempotent — no-ops if already
    /// installed. Cancels any other in-flight download first.
    ///
    /// Throws on network failure, checksum mismatch, cancellation, or unknown id.
    func download(_ id: String) async throws {
        guard let model = WhisperModelCatalog.model(id: id) else {
            throw NSError(domain: "ModelManager", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown model id: \(id)"])
        }
        if isInstalled(id) { return }
        if let cur = inFlight, cur.id == id { return }
        cancelCurrent()
        lastError = nil

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: model.downloadURL)
            inFlight = InFlight(id: id, task: task, continuation: cont)
            downloadState = .downloading(id: id, bytesReceived: 0, bytesExpected: model.sizeBytes)
            log.info("Starting download \(model.filename, privacy: .public) (\(model.sizeBytes) bytes)")
            task.resume()
        }
    }

    /// Cancels the active download (if any). Resumes its continuation with
    /// `CancellationError`. Safe to call when nothing is in flight.
    func cancelCurrent() {
        guard let cur = inFlight else { return }
        log.info("Cancelling download \(cur.id, privacy: .public)")
        cur.task.cancel()
        inFlight = nil
        downloadState = .idle
        cur.continuation.resume(throwing: CancellationError())
    }

    // MARK: - Delete

    /// Removes an installed model from disk.
    /// No-op if the id isn't installed.
    func delete(_ id: String) throws {
        guard let model = WhisperModelCatalog.model(id: id) else { return }
        let url = localURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            log.info("Deleted model \(model.filename, privacy: .public)")
        }
        installedIDs.remove(id)
    }

    // MARK: - Helpers

    /// Removes any leftover `download-*.bin` staging files (e.g. from a crash).
    private func cleanupOrphanStagingFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("download-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Total bytes consumed by installed models. For UI footer.
    var totalDiskUsageBytes: Int64 {
        WhisperModelCatalog.all
            .filter { installedIDs.contains($0.id) }
            .reduce(into: 0 as Int64) { $0 += $1.sizeBytes }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor [weak self] in
            guard let self,
                  let cur = self.inFlight,
                  cur.task === downloadTask else { return }
            let expected = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : (WhisperModelCatalog.model(id: cur.id)?.sizeBytes ?? -1)
            self.downloadState = .downloading(id: cur.id,
                                              bytesReceived: totalBytesWritten,
                                              bytesExpected: expected)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Apple deletes `location` as soon as we return — synchronously move
        // the bytes into our directory before handing off to MainActor.
        let staging = modelsDirectory
            .appendingPathComponent("download-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor [weak self] in
                self?.handleFailure(task: downloadTask, error: error, stagingToDelete: nil)
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.completeDownload(task: downloadTask, stagedFileAt: staging)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        // Success path is handled in `didFinishDownloadingTo`. This catches
        // network errors, HTTP errors that prevented body delivery, and cancel.
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.handleFailure(task: task as? URLSessionDownloadTask,
                                error: error,
                                stagingToDelete: nil)
        }
    }
}

// MARK: - Verification + atomic rename (MainActor side)

private extension ModelManager {

    func completeDownload(task: URLSessionDownloadTask, stagedFileAt staging: URL) {
        guard let cur = inFlight, cur.task === task else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        guard let model = WhisperModelCatalog.model(id: cur.id) else {
            try? FileManager.default.removeItem(at: staging)
            inFlight = nil
            downloadState = .idle
            cur.continuation.resume(throwing: NSError(
                domain: "ModelManager", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Catalog entry vanished"]))
            return
        }

        downloadState = .verifying(id: model.id)
        log.info("Verifying \(model.filename, privacy: .public)")

        let final = localURL(for: model)
        let expected = model.sha256

        // Hashing 1 GB is CPU-bound; do it off the main actor.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let actual = try Self.sha256Hex(of: staging)
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: staging)
                    throw NSError(domain: "ModelManager", code: 400,
                        userInfo: [NSLocalizedDescriptionKey:
                                    "Checksum mismatch (got \(actual.prefix(12))…, expected \(expected.prefix(12))…)"])
                }
                if FileManager.default.fileExists(atPath: final.path) {
                    try FileManager.default.removeItem(at: final)
                }
                try FileManager.default.moveItem(at: staging, to: final)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.installedIDs.insert(model.id)
                    self.downloadState = .idle
                    log.info("Installed \(model.filename, privacy: .public)")
                    if let cur = self.inFlight, cur.task === task {
                        self.inFlight = nil
                        cur.continuation.resume()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.handleFailure(task: task, error: error, stagingToDelete: staging)
                }
            }
        }
    }

    func handleFailure(task: URLSessionDownloadTask?,
                       error: Error,
                       stagingToDelete: URL?) {
        if let staging = stagingToDelete {
            try? FileManager.default.removeItem(at: staging)
        }
        cleanupOrphanStagingFiles()

        guard let cur = inFlight, cur.task === task else { return }
        inFlight = nil
        downloadState = .idle

        let nsError = error as NSError
        // NSURLErrorCancelled & CancellationError are user-initiated; keep lastError clean
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            cur.continuation.resume(throwing: CancellationError())
            return
        }
        if error is CancellationError {
            cur.continuation.resume(throwing: error)
            return
        }
        log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        lastError = error.localizedDescription
        cur.continuation.resume(throwing: error)
    }

    /// Streaming SHA-256 of a file, lowercase hex. Reads in 1 MB chunks so we
    /// can hash multi-GB files without loading them into memory.
    /// `nonisolated` so it's callable from the background `Task.detached` that
    /// performs verification.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 * 1024 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
