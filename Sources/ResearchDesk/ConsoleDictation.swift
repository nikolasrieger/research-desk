import SwiftUI
import AVFoundation
import Speech

@MainActor final class ConsoleDictation: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    func toggle(insert: @escaping @MainActor (String) -> Void) {
        if recording {
            recorder?.stop()
            recorder = nil
            recording = false
            guard let url = audioURL else { return }
            busy = true
            status = "Transcribing on this Mac…"
            let token = generation
            work = Task {
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    guard #available(macOS 26.0, *) else { return }
                    let text = try await Self.transcribe(url)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    let safe = Self.inputText(text)
                    if safe.isEmpty { status = "No speech detected. Try again." }
                    else { insert(safe); status = "" }
                } catch {
                    if generation == token { status = error.localizedDescription }
                }
                if generation == token { busy = false; audioURL = nil }
            }
            return
        }
        guard !busy else { return }
        busy = true
        status = "Preparing local dictation…"
        let token = generation
        work = Task {
            do {
                guard #available(macOS 26.0, *) else {
                    throw DictationError.message("Local dictation requires macOS 26 or later.")
                }
                guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                    throw DictationError.message("Open dist/ResearchDesk.app to use dictation with microphone permission.")
                }
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw DictationError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.")
                }
                try Task.checkCancellation()
                let transcriber = try await Self.makeTranscriber()
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    status = "Downloading the on-device speech model…"
                    try await request.downloadAndInstall()
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("research-desk-dictation-\(UUID()).wav")
                audioURL = url
                let capture = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false
                ])
                guard capture.record() else { throw DictationError.message("Could not start the microphone.") }
                recorder = capture
                recording = true
                status = "Listening — click Stop dictation to insert."
            } catch {
                if generation == token {
                    status = error.localizedDescription
                    removeAudio()
                }
            }
            if generation == token { busy = false }
        }
    }

    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        recorder?.stop()
        recorder = nil
        removeAudio()
        recording = false
        busy = false
        status = ""
    }

    private func removeAudio() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }

    // A transcript must never inject Return, Escape, or terminal control bytes.
    static func inputText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26.0, *)
    private static func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw DictationError.message("On-device speech recognition is unavailable for this Mac or system language.")
        }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    @available(macOS 26.0, *)
    private nonisolated static func transcribe(_ url: URL) async throws -> String {
        let transcriber = try await makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        return try await withTaskCancellationHandler {
            do {
                let file = try AVAudioFile(forReading: url)
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                return try await results.value
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

private enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
