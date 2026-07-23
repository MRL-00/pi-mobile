import AVFoundation
import Foundation
import Speech

@Observable
@MainActor
final class SpeechDictation {
    private(set) var isListening = false
    private(set) var transcript = ""
    var errorMessage: String?

    private var recognizer = SFSpeechRecognizer(locale: .current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var baseText = ""
    private var hasTap = false
    /// Bumped on every stop/start so late recognition callbacks can't tear down a new session.
    private var sessionID = UUID()
    private var stopping = false

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func toggle(into draft: inout String) {
        if isListening {
            stop()
        } else {
            start(seed: draft)
        }
    }

    func start(seed: String) {
        errorMessage = nil
        baseText = seed
        transcript = seed

        // Simulator ASR is unreliable ("Failed to initialize recognizer") — fail fast
        // with a clear message instead of flashing the mic.
        if isSimulator {
            errorMessage = "Dictation isn’t available in the iOS Simulator. Use a physical iPhone, or type with the software keyboard."
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized:
                    break
                case .denied, .restricted:
                    self.errorMessage = "Speech recognition is not allowed. Enable it in Settings → Pi Companion."
                    return
                case .notDetermined:
                    self.errorMessage = "Speech recognition permission was not granted."
                    return
                @unknown default:
                    self.errorMessage = "Speech recognition is unavailable."
                    return
                }

                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.errorMessage = "Microphone access is required for dictation."
                            return
                        }
                        self.beginSession()
                    }
                }
            }
        }
    }

    private func beginSession() {
        teardownAudio()

        guard let recognizer else {
            errorMessage = "No speech recognizer for the current locale."
            return
        }
        guard recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable right now."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }

        let id = UUID()
        sessionID = id
        stopping = false

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        request = req

        guard let format = recordingFormat() else {
            errorMessage = "Microphone format is unavailable."
            teardownAudio()
            return
        }

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, !self.stopping else { return }
            self.request?.append(buffer)
        }
        hasTap = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            teardownAudio()
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.sessionID == id, !self.stopping else { return }

                if let result {
                    let spoken = result.bestTranscription.formattedString
                    if self.baseText.isEmpty {
                        self.transcript = spoken
                    } else if spoken.isEmpty {
                        self.transcript = self.baseText
                    } else {
                        let needsSpace = !self.baseText.hasSuffix(" ")
                        self.transcript = self.baseText + (needsSpace ? " " : "") + spoken
                    }
                    if result.isFinal {
                        // Defer stop so observers see the final transcript while
                        // isListening is still true (ChatView only syncs then).
                        Task { @MainActor in self.stop() }
                    }
                }

                if let error {
                    if Self.isCancellation(error) { return }
                    let ns = error as NSError
                    // Ignore transient “no speech yet” assistant codes.
                    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 || ns.code == 1111 {
                        return
                    }
                    self.errorMessage = "Dictation failed: \(error.localizedDescription)"
                    self.stop()
                }
            }
        }

        isListening = true
    }

    private func recordingFormat() -> AVAudioFormat? {
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0 {
            return hardware
        }
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        guard sampleRate > 0 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    func stop() {
        guard isListening || hasTap || task != nil || request != nil else { return }
        stopping = true
        sessionID = UUID()
        request?.endAudio()
        teardownAudio()
    }

    private func teardownAudio() {
        if engine.isRunning { engine.stop() }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        stopping = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 216 || ns.code == 301) { return true }
        let msg = ns.localizedDescription.lowercased()
        return msg.contains("cancel") || msg.contains("canceled") || msg.contains("cancelled")
    }
}
