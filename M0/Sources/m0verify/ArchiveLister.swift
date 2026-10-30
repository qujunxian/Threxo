import Foundation

struct ArchiveEntry: Sendable {
    let path: String
    let size: Int64
    let isDirectory: Bool
}

enum ArchiveLister {
    /// Parses `7zz l -slt -ba` output. Records are separated by blank lines.
    static func parse(_ text: String) -> [ArchiveEntry] {
        var result: [ArchiveEntry] = []
        var current: [String: String] = [:]

        func flush() {
            defer { current = [:] }
            guard let path = current["Path"], !path.isEmpty else { return }
            let isDirectory = current["Folder"] == "+"
                || (current["Attributes"]?.hasPrefix("D") ?? false)
            let size = Int64(current["Size"] ?? "0") ?? 0
            result.append(ArchiveEntry(path: path, size: size, isDirectory: isDirectory))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            current[key] = String(value)
        }
        flush()
        return result
    }
}
