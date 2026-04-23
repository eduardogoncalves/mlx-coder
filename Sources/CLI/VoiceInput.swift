// Sources/CLI/VoiceInput.swift
// Voice-to-text input via Apple's Speech Recognition framework (macOS).

import Foundation

#if canImport(Speech)
import Speech
import AVFoundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Error type

/// Errors thrown by ``VoiceInput/transcribe(silenceTimeout:)``.
public enum VoiceInputError: Error, LocalizedError {
    case notAvailable
    case notAuthorized
    case audioEngineFailure(String)
    case noTranscription

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition is not available on this device or locale."
        case .notAuthorized:
            return "Speech recognition permission was denied. Grant access in System Settings → Privacy & Security → Speech Recognition."
        case .audioEngineFailure(let msg):
            return "Audio engine error: \(msg)"
        case .noTranscription:
            return "No speech detected."
        }
    }
}

// MARK: - Thread-safe recognition state

/// Thread-safe container for the speech recognition result accumulated so far.
private final class VoiceRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String = ""
    private var _lastSpeechDate: Date = Date()

    /// Update the recognised text (no-op when identical to the current value).
    func update(text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard text != _text else { return }
        _text = text
        _lastSpeechDate = Date()
    }

    /// Returns `(latestText, secondsSinceLastUpdate)`.
    var snapshot: (text: String, elapsed: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (_text, -_lastSpeechDate.timeIntervalSinceNow)
    }
}

// MARK: - Public API

/// Provides voice-to-text input via Apple's Speech Recognition framework.
public enum VoiceInput {

    /// Records audio from the default microphone and returns the recognised text.
    ///
    /// Recording stops automatically after `silenceTimeout` seconds without new
    /// speech, or immediately when the user presses **Enter** (or **Ctrl-C**).
    /// Live partial transcriptions are printed to `stdout` during recording.
    ///
    /// - Parameter silenceTimeout: Seconds of silence after which recording stops
    ///   automatically. Defaults to `2.0`.
    /// - Returns: The final recognised string.
    /// - Throws: ``VoiceInputError`` when speech recognition is unavailable,
    ///   unauthorised, the audio engine fails, or no speech is detected.
    public static func transcribe(silenceTimeout: TimeInterval = 2.0) async throws -> String {
        // Try the device's current locale first; fall back to English.
        let recognizer: SFSpeechRecognizer
        if let r = SFSpeechRecognizer(locale: Locale.current), r.isAvailable {
            recognizer = r
        } else if let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), r.isAvailable {
            recognizer = r
        } else {
            throw VoiceInputError.notAvailable
        }

        // Request authorisation (shows a system dialog on first use).
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw VoiceInputError.notAuthorized
        }

        let state = VoiceRecognitionState()
        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Recognition callback — runs on an arbitrary background thread.
        let recognitionTask = recognizer.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            state.update(text: text)
            // Overwrite the current terminal line with the latest partial result.
            print("\r\u{001B}[K  🎤 \u{001B}[36m\(text)\u{001B}[0m", terminator: "")
            fflush(stdout)
        }

        // Install microphone tap.
        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
            request.append(buf)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionTask.cancel()
            throw VoiceInputError.audioEngineFailure(error.localizedDescription)
        }

        // Switch terminal to raw non-blocking mode so we can detect Enter.
        var originalTerm = termios()
        tcgetattr(STDIN_FILENO, &originalTerm)
        var rawTerm = originalTerm
        rawTerm.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        rawTerm.c_cc.16 = 0 // VMIN  = 0 → non-blocking reads
        rawTerm.c_cc.17 = 0 // VTIME = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTerm)

        print("  🎤 \u{001B}[2mListening… press Enter to finish\u{001B}[0m")
        fflush(stdout)

        // Poll loop: stop on Enter / Ctrl-C / Ctrl-D, or after silence timeout.
        var shouldStop = false
        while !shouldStop {
            var b: UInt8 = 0
            if read(STDIN_FILENO, &b, 1) == 1 {
                if b == 10 || b == 13 || b == 3 || b == 4 { // Enter / Ctrl-C / Ctrl-D
                    shouldStop = true
                    continue
                }
            }
            let snap = state.snapshot
            if !snap.text.isEmpty && snap.elapsed >= silenceTimeout {
                shouldStop = true
                continue
            }
            // Yield to avoid spinning a core.
            try? await Task.sleep(nanoseconds: 40_000_000) // 40 ms
        }

        // Restore terminal, stop audio, and clean up.
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTerm)
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        request.endAudio()
        recognitionTask.cancel()
        print("\r\u{001B}[K", terminator: "") // clear partial transcription line
        fflush(stdout)

        let finalText = state.snapshot.text
        if finalText.isEmpty {
            throw VoiceInputError.noTranscription
        }
        return finalText
    }
}
#endif
