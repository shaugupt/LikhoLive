import Foundation
import OSLog

private let sarvamLog = Logger(subsystem: "com.shaugupt.LikhoLive", category: "SarvamClient")

protocol SarvamStreamingDelegate: AnyObject {
    func sarvamClient(_ client: SarvamStreamingClient, didReceiveTranscript text: String)
    func sarvamClient(_ client: SarvamStreamingClient, didReceiveVADEvent event: VADEvent)
    func sarvamClient(_ client: SarvamStreamingClient, didFailWithError error: Error)
    func sarvamClientDidClose(_ client: SarvamStreamingClient, code: URLSessionWebSocketTask.CloseCode, reason: String?)
}

enum VADEvent {
    case speechStart
    case speechEnd
}

/// Streams audio to the Sarvam saaras:v3 WebSocket STT endpoint.
final class SarvamStreamingClient: NSObject {

    weak var delegate: SarvamStreamingDelegate?

    private let baseWSS = "wss://api.sarvam.ai/speech-to-text/ws"
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private(set) var isConnected = false
    private var apiKey: String = ""
    private var mode: SarvamMode = .transcribe
    private var languageCode: String = "unknown"

    // MARK: - Connect

    func connect(apiKey: String, mode: SarvamMode, languageCode: String) {
        // Always clean up any previous session before connecting
        teardown()

        self.apiKey = apiKey
        self.mode = mode
        self.languageCode = languageCode

        var components = URLComponents(string: baseWSS)!
        components.queryItems = [
            URLQueryItem(name: "language-code",        value: languageCode),
            URLQueryItem(name: "model",                value: "saaras:v3"),
            URLQueryItem(name: "mode",                 value: mode.rawValue),
            URLQueryItem(name: "input_audio_codec",    value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate",          value: "16000"),
            URLQueryItem(name: "high_vad_sensitivity", value: "true"),
            URLQueryItem(name: "vad_signals",          value: "true"),
            URLQueryItem(name: "flush_signal",         value: "true"),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Subscription-Key")
        request.timeoutInterval = 30

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        isConnected = true
        task.resume()

        log("connect: WebSocket connecting to \(url)")
        receive()
    }

    // MARK: - Send audio

    func sendAudio(_ pcmData: Data) {
        guard isConnected else { return }

        let base64 = pcmData.base64EncodedString()
        let payload: [String: Any] = [
            "audio": [
                "data":        base64,
                "encoding":    "audio/wav",
                "sample_rate": 16000
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(json)) { _ in }
    }

    // MARK: - Flush

    func flush() {
        guard isConnected else {
            log("flush: skipped — not connected")
            return
        }
        log("flush: sending")
        webSocketTask?.send(.string(#"{"type":"flush"}"#)) { _ in }
    }

    // MARK: - Disconnect

    func disconnect() {
        log("disconnect: called")
        teardown()
    }

    // MARK: - Private teardown

    private func teardown() {
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Receive loop

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.log("receive error: \(error)")
                if self.isConnected {
                    DispatchQueue.main.async {
                        self.delegate?.sarvamClient(self, didFailWithError: error)
                    }
                }
            case .success(let message):
                self.handleMessage(message)
                if self.isConnected { self.receive() }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        var jsonString: String?
        switch message {
        case .string(let s): jsonString = s
        case .data(let d):   jsonString = String(data: d, encoding: .utf8)
        @unknown default:    return
        }

        guard let jsonString else { return }
        log("recv: \(jsonString.prefix(200))")

        guard let data = jsonString.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "data":
            if let dataObj    = obj["data"] as? [String: Any],
               let transcript = dataObj["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async {
                    self.delegate?.sarvamClient(self, didReceiveTranscript: transcript)
                }
            }

        case "events":
            if let dataObj    = obj["data"] as? [String: Any],
               let signalType = dataObj["signal_type"] as? String {
                log("VAD event: \(signalType)")
                let event: VADEvent = signalType == "START_SPEECH" ? .speechStart : .speechEnd
                DispatchQueue.main.async {
                    self.delegate?.sarvamClient(self, didReceiveVADEvent: event)
                }
            }

        case "error":
            if let dataObj = obj["data"] as? [String: Any],
               let errMsg  = dataObj["error"] as? String {
                log("API error: \(errMsg)")
                let error = NSError(domain: "SarvamAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: errMsg])
                DispatchQueue.main.async {
                    self.delegate?.sarvamClient(self, didFailWithError: error)
                }
            }

        default:
            log("unknown message type: \(type)")
        }
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        sarvamLog.debug("[Sarvam \(ts, privacy: .public)] \(msg, privacy: .public)")
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SarvamStreamingClient: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        log("WebSocket opened")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        log("WebSocket closed — code: \(closeCode.rawValue), reason: \(reasonStr ?? "nil")")
        let wasConnected = isConnected
        isConnected = false
        webSocketTask.cancel(with: .normalClosure, reason: nil)
        // Only notify if we thought we were still connected (unexpected close)
        if wasConnected {
            DispatchQueue.main.async {
                self.delegate?.sarvamClientDidClose(self, code: closeCode, reason: reasonStr)
            }
        }
    }
}
