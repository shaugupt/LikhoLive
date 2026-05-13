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

/// Active transcription backend. Persisted in `AppSettings.engine`.
///
/// Whisper runs the GGML model locally via whisper.cpp; Sarvam streams audio to
/// `saaras:v3` over WebSocket. Each engine has its own mode and language settings —
/// see `SarvamMode` / `WhisperMode` and the per-engine language codes.
enum Engine: String, CaseIterable, Codable {
    case whisper
    case sarvam

    var displayName: String {
        switch self {
        case .whisper: return "Whisper (local)"
        case .sarvam:  return "Sarvam (cloud)"
        }
    }
}

/// Whisper inference modes. Maps directly onto whisper.cpp's `translate` flag —
/// `transcribe` keeps the source language, `translate` cross-decodes to English.
/// Whisper.cpp doesn't have Sarvam-style verbatim/translit/codemix variants.
enum WhisperMode: String, CaseIterable, Codable {
    case transcribe
    case translate

    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .transcribe: return "Transcribe in spoken language"
        case .translate:  return "Translate any language → English"
        }
    }
}

/// Magic value for "let whisper.cpp pick the language at decode time".
/// Stored in `AppSettings.whisperLanguageCode` as the default.
let whisperLanguageAuto = "auto"

/// A subset of whisper.cpp's ~99 supported languages. We surface the
/// languages most relevant to the LikhoLive audience (auto + Indian languages
/// + a handful of widely-used non-Indian ones). Whisper accepts ISO 639-1
/// where applicable; "auto" maps to nil (auto-detect) on the wrapper.
struct WhisperLanguage: Identifiable, Equatable {
    let id: String          // ISO code stored and passed to whisper, or "auto"
    let displayName: String

    static let all: [WhisperLanguage] = [
        .init(id: whisperLanguageAuto, displayName: "Auto-detect"),
        .init(id: "en",  displayName: "English"),
        .init(id: "hi",  displayName: "Hindi"),
        .init(id: "bn",  displayName: "Bengali"),
        .init(id: "gu",  displayName: "Gujarati"),
        .init(id: "kn",  displayName: "Kannada"),
        .init(id: "ml",  displayName: "Malayalam"),
        .init(id: "mr",  displayName: "Marathi"),
        .init(id: "pa",  displayName: "Punjabi"),
        .init(id: "ta",  displayName: "Tamil"),
        .init(id: "te",  displayName: "Telugu"),
        .init(id: "ur",  displayName: "Urdu"),
        .init(id: "ne",  displayName: "Nepali"),
        .init(id: "sa",  displayName: "Sanskrit"),
        .init(id: "es",  displayName: "Spanish"),
        .init(id: "fr",  displayName: "French"),
        .init(id: "de",  displayName: "German"),
        .init(id: "ja",  displayName: "Japanese"),
        .init(id: "zh",  displayName: "Chinese"),
        .init(id: "ar",  displayName: "Arabic"),
    ]

    static let defaultLanguage = WhisperLanguage.all[0] // auto
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

/// A completed session stored in history. Engine-agnostic: `mode` is the raw
/// string of whichever per-engine mode enum was active (`SarvamMode` or
/// `WhisperMode`). Pre-v2 sessions on disk had no `engine` field; the custom
/// decoder backfills `.sarvam` for those so existing history loads cleanly.
struct TranscriptSession: Identifiable, Codable {
    let id: UUID
    let date: Date
    let segments: [TranscriptSegment]
    let engine: Engine
    let mode: String
    let languageCode: String

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    init(segments: [TranscriptSegment],
         engine: Engine,
         mode: String,
         languageCode: String) {
        self.id = UUID()
        self.date = .now
        self.segments = segments
        self.engine = engine
        self.mode = mode
        self.languageCode = languageCode
    }

    enum CodingKeys: String, CodingKey {
        case id, date, segments, engine, mode, languageCode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self, forKey: .id)
        self.date         = try c.decode(Date.self, forKey: .date)
        self.segments     = try c.decode([TranscriptSegment].self, forKey: .segments)
        self.mode         = try c.decode(String.self, forKey: .mode)
        self.languageCode = try c.decode(String.self, forKey: .languageCode)
        self.engine       = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .sarvam
    }
}
