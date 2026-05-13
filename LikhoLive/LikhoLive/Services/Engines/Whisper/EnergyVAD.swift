import Foundation

/// Voice-activity classification of one short audio chunk, based on RMS energy
/// against a fixed threshold.
enum VADChunkClass {
    case speech
    case silence
}

/// Lightweight energy-based voice-activity detector.
///
/// We chose this over whisper.cpp's bundled Silero-V5 streaming detector because
/// (a) Silero v1.8.4 only exposes a *batch* API in the C header — it can't tell
/// us "is the user speaking right now?" frame by frame; (b) RMS thresholding is
/// fast (no extra model load, no per-chunk inference cost) and (c) for the
/// dictation use case (close-mic, low ambient, indoor) energy alone gets us
/// good-enough false-positive rates.
///
/// If quality becomes an issue (noisy environments, far-field mics), a future
/// revision can swap in Silero by:
///   1. Shipping `ggml-silero-v5.bin` via `WhisperModelCatalog`
///   2. Replacing this struct's `classify(samples:)` with a call into
///      `whisper_vad_detect_speech` over a sliding window.
/// `WhisperEngine` only depends on `VADChunkClass` so the swap is isolated.
struct EnergyVAD {

    /// Linear RMS at-or-above this value ⇒ classified as speech.
    /// 0.02 corresponds to ≈ -34 dBFS — comfortably above typical room noise on
    /// laptop mics but well below normal-volume speech (~-15 to -25 dBFS).
    /// Tuned conservatively to err on the side of detecting speech rather than
    /// missing it; missed speech bytes are unrecoverable but spurious "speech"
    /// just delays the eventual silence-flush by 800 ms.
    var speechThreshold: Float = 0.02

    /// Classify a chunk of Float32 samples in [-1, 1] as speech or silence.
    /// Empty input ⇒ silence. Caller is expected to pass roughly-uniform-length
    /// chunks; mixing 60 ms and 5 s chunks would give very different RMS values.
    func classify(samples: ArraySlice<Float>) -> VADChunkClass {
        guard !samples.isEmpty else { return .silence }
        var sumOfSquares: Float = 0
        for s in samples { sumOfSquares += s * s }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        return rms >= speechThreshold ? .speech : .silence
    }

    /// Convenience overload for full arrays.
    func classify(samples: [Float]) -> VADChunkClass {
        classify(samples: samples[...])
    }
}
