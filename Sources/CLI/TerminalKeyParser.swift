// Sources/CLI/TerminalKeyParser.swift
// Shared low-level keyboard parsing helpers for raw terminal input.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum TerminalArrowDirection: Equatable {
    case up
    case down
    case right
    case left
}

enum TerminalEscapeClassification: Equatable {
    case bare
    case csiOrSS3([UInt8])
    case alt([UInt8])
}

enum TerminalKeyParser {
    static func readEscapeSequence(
        initialTimeoutMs: Int32 = 120,
        extendedTimeoutMs: Int32 = 250,
        maxBytes: Int = 10
    ) -> [UInt8] {
        var sequence: [UInt8] = []
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        var timeoutMs = initialTimeoutMs

        while true {
            let ready = poll(&pfd, 1, timeoutMs)
            if ready <= 0 { break }

            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) <= 0 { break }
            sequence.append(byte)

            if sequence.count == 1 && (byte == 91 || byte == 79) {
                timeoutMs = extendedTimeoutMs
            }

            if sequence.count == 1 && byte != 91 && byte != 79 { break }
            if sequence.count > 1 && byte >= 64 && byte <= 126 { break }
            if sequence.count >= maxBytes { break }
        }

        return sequence
    }

    static func classifyEscapeSequence(_ sequence: [UInt8]) -> TerminalEscapeClassification {
        guard let first = sequence.first else {
            return .bare
        }

        if first == 91 || first == 79 {
            return .csiOrSS3(sequence)
        }

        return .alt(sequence)
    }

    static func arrowDirection(for sequence: [UInt8]) -> TerminalArrowDirection? {
        guard sequence.count >= 2, let first = sequence.first, first == 91 || first == 79 else {
            return nil
        }

        switch sequence.last {
        case 65: return .up
        case 66: return .down
        case 67: return .right
        case 68: return .left
        default: return nil
        }
    }

    static func numericSelection(for byte: UInt8, allowThirdOption: Bool) -> Int? {
        if byte == 49 { return 0 }
        if byte == 50 { return 1 }
        if byte == 51 && allowThirdOption { return 2 }
        return nil
    }

    static func numericSelection(forEscapeSequence sequence: [UInt8], allowThirdOption: Bool) -> Int? {
        // Keypad digits in application mode often arrive as Esc O q/r/s for 1/2/3.
        guard sequence.count >= 2, sequence.first == 79 else { return nil }

        if sequence.last == 113 { return 0 }
        if sequence.last == 114 { return 1 }
        if sequence.last == 115 && allowThirdOption { return 2 }
        return nil
    }

    static func drainAvailableInput() {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 0) > 0 {
            var byte: UInt8 = 0
            if read(STDIN_FILENO, &byte, 1) <= 0 { break }
        }
    }
}
