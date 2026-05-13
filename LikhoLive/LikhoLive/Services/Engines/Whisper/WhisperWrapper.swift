import Foundation
import OSLog
import whisper

private let log = Logger(subsystem: "com.shaugupt.LikhoLive", category: "WhisperWrapper")

/// Thin Swift facade over the whisper.cpp C API.
///
/// Owns a `whisper_context` and exposes a synchronous transcribe-from-Float-PCM method.
/// All inference is heavy work — call from a background thread / serial queue.
///
/// Lifetime: one instance per loaded model. Reusable across many transcribe calls;
/// release by deinit when the model is no longer needed (e.g. user changes model).
final class WhisperWrapper {

    // MARK: - Errors

    enum WhisperError: LocalizedError {
        case modelLoadFailed(URL)
        case noContext
        case inferenceFailed(Int32)
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let url): return "Failed to load whisper model at \(url.path)"
            case .noContext:                return "Whisper context not initialized"
            case .inferenceFailed(let code): return "whisper_full failed with code \(code)"
            case .noTranscript:             return "Whisper produced no transcript"
            }
        }
    }

    // MARK: - Inference config

    /// Configuration for a single `transcribe` call.
    /// Defaults are tuned for low-latency dictation with greedy sampling.
    struct InferenceConfig {
        /// Two-letter ISO 639 code (e.g. "hi", "en"). `nil` ⇒ auto-detect.
        var language: String? = nil
        /// True for translate-to-English; false for transcribe-in-source-language.
        var translate: Bool = false
        /// CPU thread count for the decoder. 0 ⇒ use ProcessInfo logical core count.
        var threads: Int32 = 0
        /// Suppress non-speech tokens (e.g. clicks/breaths). Recommended: true.
        var suppressNonSpeech: Bool = true
        /// Suppress blank tokens. Recommended: true.
        var suppressBlank: Bool = true
    }

    // MARK: - State

    private var ctx: OpaquePointer?

    // MARK: - Lifecycle

    /// Loads a GGML model from disk.
    ///
    /// `useGPU = true` enables Metal acceleration on Apple Silicon — strongly recommended.
    /// `flashAttn` requires recent ggml; safe default is false (some quantized models are unstable with it).
    init(modelURL: URL, useGPU: Bool = true, flashAttn: Bool = false) throws {
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        params.flash_attn = flashAttn

        let path = modelURL.path
        log.info("Loading whisper model from \(path, privacy: .public) (gpu=\(useGPU), flash_attn=\(flashAttn))")

        let loaded: OpaquePointer? = path.withCString { cpath in
            whisper_init_from_file_with_params(cpath, params)
        }
        guard let loaded else {
            throw WhisperError.modelLoadFailed(modelURL)
        }
        self.ctx = loaded
        log.info("Whisper model loaded — system_info: \(String(cString: whisper_print_system_info()), privacy: .public)")
    }

    deinit {
        if let ctx {
            whisper_free(ctx)
            log.debug("Whisper context freed")
        }
    }

    // MARK: - Inference

    /// Synchronously transcribes a buffer of 16 kHz mono Float32 samples in `[-1.0, 1.0]`.
    /// Returns the concatenated text across all decoded segments, trimmed.
    ///
    /// Heavy: typical wall time on Apple Silicon for a 5 s clip with `small.q5_0` is
    /// ~300–600 ms. Always call from a background thread — never the main queue.
    func transcribe(samples: [Float], config: InferenceConfig = InferenceConfig()) throws -> String {
        guard let ctx else { throw WhisperError.noContext }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime   = false
        params.print_progress   = false
        params.print_timestamps = false
        params.print_special    = false
        params.translate        = config.translate
        params.no_context       = true
        params.single_segment   = false
        params.suppress_blank   = config.suppressBlank
        params.suppress_nst     = config.suppressNonSpeech
        params.n_threads        = config.threads > 0
            ? config.threads
            : Int32(ProcessInfo.processInfo.activeProcessorCount)

        // Language pointer must outlive the `whisper_full` call. whisper_full_params
        // stores `const char *` by reference and does not copy.
        var languageBuffer: ContiguousArray<CChar>?
        if let lang = config.language {
            // strdup-style safe storage tied to the function's lifetime
            var arr = ContiguousArray<CChar>(lang.utf8.map { CChar(bitPattern: $0) })
            arr.append(0)
            languageBuffer = arr
            params.language = languageBuffer!.withUnsafeBufferPointer { $0.baseAddress }
        } else {
            params.language = nil
        }

        let result: Int32 = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        // Keep `languageBuffer` alive until after `whisper_full` returns.
        _ = languageBuffer

        guard result == 0 else {
            log.error("whisper_full failed: \(result, privacy: .public)")
            throw WhisperError.inferenceFailed(result)
        }

        let n = whisper_full_n_segments(ctx)
        guard n > 0 else { throw WhisperError.noTranscript }

        var out = ""
        for i in 0..<n {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                out += String(cString: cstr)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
