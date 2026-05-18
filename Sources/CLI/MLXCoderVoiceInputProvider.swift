// Sources/CLI/MLXCoderVoiceInputProvider.swift
// Bridges the SwiftCoderTUI `VoiceInputProvider` protocol to mlx-coder's
// `VoiceInput.transcribe`. Lives in CLI (not the dependency) so we can pass
// per-session settings (silence timeout, locale) without modifying the TUI
// package.
//
// The provider runs `VoiceInput.transcribe(interactive: false, …)` so that
// the TUI's background stdin reader keeps owning the terminal. Recording
// stops on silence after speech (or after a hard `maxDuration` safety cap)
// instead of on Enter — the TUI shows a "Listening…" spinner via
// `Renderer.triggerVoiceInput` while the recording is in progress.

import Foundation
import SwiftCoderTUI

/// Voice provider for the SwiftCoderTUI shell.
///
/// A reference type so the TUI session loop can keep a shared handle and call
/// ``requestStop()`` (e.g. when the user presses Enter while recording) — the
/// same instance is also stored in `AppConfig.voiceInputProvider`, so the
/// renderer-driven `triggerVoiceInput` flow and the keystroke loop observe the
/// same stop flag.
public final class MLXCoderVoiceInputProvider: VoiceInputProvider, @unchecked Sendable {
    public let silenceTimeout: TimeInterval
    public let locale: Locale?
    public let maxDuration: TimeInterval

    private let lock = NSLock()
    private var _stopRequested = false
    private var _isRecording = false

    public init(
        silenceTimeout: TimeInterval = 2.0,
        locale: Locale? = nil,
        maxDuration: TimeInterval = 60.0
    ) {
        self.silenceTimeout = silenceTimeout
        self.locale = locale
        self.maxDuration = maxDuration
    }

    /// Signal the in-flight `transcribe()` to stop on the next poll tick.
    public func requestStop() {
        lock.lock(); defer { lock.unlock() }
        _stopRequested = true
    }

    /// Returns true while a `transcribe()` call is active.
    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecording
    }

    private func beginRecording() {
        lock.lock(); defer { lock.unlock() }
        _stopRequested = false
        _isRecording = true
    }

    private func endRecording() {
        lock.lock(); defer { lock.unlock() }
        _isRecording = false
    }

    private func stopRequestedSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopRequested
    }

    public func transcribe() async throws -> String {
        #if canImport(Speech)
        beginRecording()
        defer { endRecording() }
        return try await VoiceInput.transcribe(
            silenceTimeout: silenceTimeout,
            locale: locale,
            interactive: false,
            maxDuration: maxDuration,
            stopRequested: { [weak self] in self?.stopRequestedSnapshot() ?? false }
        )
        #else
        throw NSError(
            domain: "MLXCoderVoiceInputProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Voice input requires macOS with the Speech framework."]
        )
        #endif
    }
}
