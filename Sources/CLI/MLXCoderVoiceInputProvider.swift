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

public struct MLXCoderVoiceInputProvider: VoiceInputProvider {
    public let silenceTimeout: TimeInterval
    public let locale: Locale?
    public let maxDuration: TimeInterval

    public init(
        silenceTimeout: TimeInterval = 2.0,
        locale: Locale? = nil,
        maxDuration: TimeInterval = 60.0
    ) {
        self.silenceTimeout = silenceTimeout
        self.locale = locale
        self.maxDuration = maxDuration
    }

    public func transcribe() async throws -> String {
        #if canImport(Speech)
        return try await VoiceInput.transcribe(
            silenceTimeout: silenceTimeout,
            locale: locale,
            interactive: false,
            maxDuration: maxDuration
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
