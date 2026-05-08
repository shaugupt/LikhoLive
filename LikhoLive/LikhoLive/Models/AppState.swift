import Foundation

/// Top-level session state machine for LikhoLive.
enum SessionState: Equatable {
    case idle
    case listening
    case finalizing          // sent flush, waiting for last segment(s)
    case stopped
    case error(String)

    var isActive: Bool {
        self == .listening || self == .finalizing
    }

    var displayLabel: String {
        switch self {
        case .idle:        return "Idle"
        case .listening:   return "Listening…"
        case .finalizing:  return "Finalizing…"
        case .stopped:     return "Stopped"
        case .error(let m): return "Error: \(m)"
        }
    }
}

/// All five Sarvam saaras:v3 modes, using exact Sarvam terminology.
enum SarvamMode: String, CaseIterable, Codable {
    case transcribe
    case translate
    case verbatim
    case translit
    case codemix

    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .transcribe: return "Standard transcription in spoken language"
        case .translate:  return "Translate any language → English"
        case .verbatim:   return "Word-for-word, no normalisation"
        case .translit:   return "Romanise output (Latin script)"
        case .codemix:    return "English in English, Indic in native script"
        }
    }
}

/// Sarvam-supported language codes (saaras:v3 full list).
struct SarvamLanguage: Identifiable, Equatable {
    let id: String          // BCP-47 code stored and sent to API
    let displayName: String

    static let all: [SarvamLanguage] = [
        .init(id: "unknown",  displayName: "Auto-detect"),
        .init(id: "en-IN",    displayName: "English (India)"),
        .init(id: "hi-IN",    displayName: "Hindi"),
        .init(id: "bn-IN",    displayName: "Bengali"),
        .init(id: "gu-IN",    displayName: "Gujarati"),
        .init(id: "kn-IN",    displayName: "Kannada"),
        .init(id: "ml-IN",    displayName: "Malayalam"),
        .init(id: "mr-IN",    displayName: "Marathi"),
        .init(id: "od-IN",    displayName: "Odia"),
        .init(id: "pa-IN",    displayName: "Punjabi"),
        .init(id: "ta-IN",    displayName: "Tamil"),
        .init(id: "te-IN",    displayName: "Telugu"),
        .init(id: "as-IN",    displayName: "Assamese"),
        .init(id: "ur-IN",    displayName: "Urdu"),
        .init(id: "ne-IN",    displayName: "Nepali"),
        .init(id: "kok-IN",   displayName: "Konkani"),
        .init(id: "ks-IN",    displayName: "Kashmiri"),
        .init(id: "sd-IN",    displayName: "Sindhi"),
        .init(id: "sa-IN",    displayName: "Sanskrit"),
        .init(id: "sat-IN",   displayName: "Santali"),
        .init(id: "mni-IN",   displayName: "Manipuri"),
        .init(id: "brx-IN",   displayName: "Bodo"),
        .init(id: "mai-IN",   displayName: "Maithili"),
        .init(id: "doi-IN",   displayName: "Dogri"),
    ]

    static let defaultLanguage = SarvamLanguage.all[0] // unknown
}

/// A single finalized transcript segment returned by Sarvam.
struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(text: String, timestamp: Date = .now) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
    }
}

/// A completed session stored in history.
struct TranscriptSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    let segments: [TranscriptSegment]
    let mode: SarvamMode
    let languageCode: String

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    init(segments: [TranscriptSegment], mode: SarvamMode, languageCode: String) {
        self.id = UUID()
        self.date = .now
        self.segments = segments
        self.mode = mode
        self.languageCode = languageCode
    }
}
