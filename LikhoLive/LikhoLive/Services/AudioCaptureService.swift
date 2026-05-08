import AVFoundation
import Foundation

protocol AudioCaptureDelegate: AnyObject {
    /// Called with each raw PCM chunk (mono, 16kHz, Int16 samples, little-endian).
    func audioCaptureService(_ service: AudioCaptureService, didCapture pcmData: Data)
    /// Called when capture encounters a fatal error.
    func audioCaptureService(_ service: AudioCaptureService, didFailWithError error: Error)
}

/// Captures microphone audio using AVAudioEngine.
/// Delivers mono 16-bit PCM at 16 kHz in small chunks for low-latency streaming.
final class AudioCaptureService {

    weak var delegate: AudioCaptureDelegate?

    // Sarvam expects 16kHz, 16-bit PCM, mono
    private let targetSampleRate: Double = 16_000
    private let chunkDuration: Double    = 0.06  // 60ms chunks — lower latency than 100ms

    private let engine     = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning  = false
    private var configObserver: NSObjectProtocol?

    // MARK: - Public

    func start() throws {
        guard !isRunning else { return }

        try setupAndStartEngine()

        // AVAudioEngineConfigurationChange fires when the OS reconfigures audio
        // (e.g. another app starts capturing, Bluetooth device switches, mic changes).
        // This is NOT fatal — we just need to rebuild the tap and restart the engine.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineReconfiguration()
        }
    }

    func stop() {
        guard isRunning else { return }
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: - Private setup

    private func setupAndStartEngine() throws {
        // Remove any existing tap before reinstalling
        engine.inputNode.removeTap(onBus: 0)

        let inputNode   = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: mono, 16kHz, Int16
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw CaptureError.formatUnsupported
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = conv

        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * chunkDuration)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: conv, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Called when the OS reconfigures the audio hardware (not a fatal error).
    /// Rebuilds the tap and restarts the engine silently — session keeps running.
    private func handleEngineReconfiguration() {
        guard isRunning else { return }
        do {
            try setupAndStartEngine()
        } catch {
            // Only escalate to fatal if we genuinely cannot restart
            delegate?.audioCaptureService(self, didFailWithError: error)
        }
    }

    // MARK: - Private

    private func process(buffer: AVAudioPCMBuffer,
                         converter: AVAudioConverter,
                         targetFormat: AVAudioFormat) {
        // Calculate expected output frame count
        let ratio = targetSampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            delegate?.audioCaptureService(self, didFailWithError: error)
            return
        }

        guard status != .error, outBuffer.frameLength > 0 else { return }

        // Extract raw bytes from Int16 channel data
        let frameCount = Int(outBuffer.frameLength)
        guard let channelData = outBuffer.int16ChannelData?[0] else { return }
        let data = Data(bytes: channelData, count: frameCount * 2) // 2 bytes per Int16

        delegate?.audioCaptureService(self, didCapture: data)
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case formatUnsupported
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .formatUnsupported:       return "Microphone audio format is not supported."
            case .converterCreationFailed: return "Failed to create audio format converter."
            }
        }
    }
}
