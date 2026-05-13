import Foundation

/// One downloadable whisper.cpp GGML model from the official
/// `ggerganov/whisper.cpp` HuggingFace repo.
///
/// The `id` is the persistence key written into UserDefaults — keep it stable
/// across releases; if a filename changes upstream, add a migration mapping
/// rather than reusing an existing id with a new payload.
struct WhisperModel: Identifiable, Hashable, Codable, Sendable {
    /// Stable persistence key (e.g. `"small-q5_1"`).
    let id: String
    /// Human-readable label shown in the UI (e.g. `"Small (multilingual)"`).
    let displayName: String
    /// Optional one-line note ("Recommended", "Slowest, highest quality", etc.).
    let note: String?
    /// Filename on the HF repo and on disk inside `models/`.
    let filename: String
    /// Direct HF resolve URL. We let URLSession follow the 302 to xethub.hf.co.
    let downloadURL: URL
    /// Expected file size in bytes. Used to display "X MB" and to size the
    /// progress bar; not used for verification (SHA-256 is the verifier).
    let sizeBytes: Int64
    /// SHA-256 of the file in hex (lowercase, 64 chars). Sourced from the HF
    /// API at `tree/main` (`lfs.oid`). Verified after download — mismatch ⇒
    /// the file is deleted and the download is reported as failed.
    let sha256: String

    /// Pretty size string for UI ("31 MB", "1.0 GB").
    var sizeDisplay: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Static catalog of models exposed in the Model Manager UI.
///
/// Only multilingual quantized variants are listed — `.en` (English-only) builds
/// are intentionally excluded since LikhoLive's value proposition is multilingual
/// dictation. Whisper.cpp's GGML repo only publishes `q5_0` for `medium`/`large*`;
/// for `tiny`/`base`/`small` the closest published quantization is `q5_1`, which
/// has near-identical size and slightly better quality than `q5_0`.
///
/// Bump procedure when adding/updating an entry:
///   1. Look up the new file at https://huggingface.co/ggerganov/whisper.cpp/tree/main
///   2. Get its SHA-256 from the HF API:
///      curl -s 'https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main?recursive=true' \
///        | jq -r '.[] | select(.path == "<filename>") | .lfs.oid'
///   3. Add/update an entry below
enum WhisperModelCatalog {

    /// HF resolve base URL — files are at `<base>/<filename>`.
    private static let resolveBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    /// The default model id auto-suggested in the first-run prompt.
    /// Chosen for the right balance of quality, latency, and download size on
    /// modern Apple Silicon. Users can pick a different model at any time.
    static let defaultModelID = "small-q5_1"

    /// Ordered for display (smallest/fastest first).
    static let all: [WhisperModel] = [
        WhisperModel(
            id: "tiny-q5_1",
            displayName: "Tiny (multilingual)",
            note: "Fastest — lowest quality",
            filename: "ggml-tiny-q5_1.bin",
            downloadURL: URL(string: "\(resolveBase)/ggml-tiny-q5_1.bin")!,
            sizeBytes: 32_152_673,
            sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
        ),
        WhisperModel(
            id: "base-q5_1",
            displayName: "Base (multilingual)",
            note: "Fast — basic quality",
            filename: "ggml-base-q5_1.bin",
            downloadURL: URL(string: "\(resolveBase)/ggml-base-q5_1.bin")!,
            sizeBytes: 59_707_625,
            sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
        ),
        WhisperModel(
            id: "small-q5_1",
            displayName: "Small (multilingual)",
            note: "Recommended — balanced quality and speed",
            filename: "ggml-small-q5_1.bin",
            downloadURL: URL(string: "\(resolveBase)/ggml-small-q5_1.bin")!,
            sizeBytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        ),
        WhisperModel(
            id: "medium-q5_0",
            displayName: "Medium (multilingual)",
            note: "High quality — slower",
            filename: "ggml-medium-q5_0.bin",
            downloadURL: URL(string: "\(resolveBase)/ggml-medium-q5_0.bin")!,
            sizeBytes: 539_212_467,
            sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f"
        ),
        WhisperModel(
            id: "large-v3-turbo-q5_0",
            displayName: "Large v3 Turbo (multilingual)",
            note: "Best quality / speed tradeoff",
            filename: "ggml-large-v3-turbo-q5_0.bin",
            downloadURL: URL(string: "\(resolveBase)/ggml-large-v3-turbo-q5_0.bin")!,
            sizeBytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        ),
        WhisperModel(
            id: "large-v3-q5_0",
            displayName: "Large v3 (multilingual)",
            note: "Highest quality — slowest, ~1 GB",
            filename: "ggml-large-v3-q5_0.bin",
            downloadURL: URL(string: "\(resolveBase)/ggml-large-v3-q5_0.bin")!,
            sizeBytes: 1_081_140_203,
            sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"
        ),
    ]

    /// Lookup by id, or `nil` if the id was renamed/removed.
    static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    /// The catalog entry chosen as the first-run default download.
    static var defaultModel: WhisperModel {
        // Force-unwrap is safe because `defaultModelID` is a constant we maintain.
        model(id: defaultModelID)!
    }
}
