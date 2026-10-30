import Foundation

struct ProgressEvent: Sendable {
    let percent: Int
    let raw: String
}

enum RunnerError: Error, CustomStringConvertible {
    case launchFailed(String)

    var description: String {
        switch self {
        case .launchFailed(let message):
            return "launch failed: \(message)"
        }
    }
}

/// Decodes a byte stream into lines. Empty lines are preserved because
/// `7zz l -slt -ba` uses blank lines as record separators.
final class LineDecoder {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let chunk = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            onLine(String(data: chunk, encoding: .utf8) ?? "")
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return }
        onLine(String(data: buffer, encoding: .utf8) ?? "")
        buffer.removeAll(keepingCapacity: false)
    }
}

final class SevenZipRunner {
    let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func start(
        arguments: [String],
        workingDirectory: URL? = nil,
        onProgress: @escaping (ProgressEvent) -> Void = { _ in },
        onLine: @escaping (String) -> Void = { _ in },
        onError: @escaping (String) -> Void = { _ in }
    ) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutDecoder = LineDecoder { line in
            let percents = SevenZipRunner.parsePercents(line)
            if percents.isEmpty {
                onLine(line)
            } else {
                // 7-Zip overwrites progress in place with backspaces, so one
                // decoder chunk can contain several percentages. Emit them all.
                for percent in percents {
                    onProgress(ProgressEvent(percent: percent, raw: line))
                }
            }
        }
        let stderrDecoder = LineDecoder { line in
            onError(line)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutDecoder.flush()
                handle.readabilityHandler = nil
                return
            }
            stdoutDecoder.feed(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrDecoder.flush()
                handle.readabilityHandler = nil
                return
            }
            stderrDecoder.feed(data)
        }

        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        return process
    }

    @discardableResult
    func run(
        arguments: [String],
        workingDirectory: URL? = nil,
        onProgress: @escaping (ProgressEvent) -> Void = { _ in },
        onLine: @escaping (String) -> Void = { _ in },
        onError: @escaping (String) -> Void = { _ in }
    ) throws -> Int32 {
        let process = try start(
            arguments: arguments,
            workingDirectory: workingDirectory,
            onProgress: onProgress,
            onLine: onLine,
            onError: onError
        )
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Extracts every `NN%` occurrence from a chunk. 7-Zip writes progress
    /// with `\b` (backspace) overwrites, so a single chunk may hold a sequence
    /// like `0%...32%...63%...93%`.
    static func parsePercents(_ text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3})%"#) else {
            return []
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[valueRange])
        }
    }
}
