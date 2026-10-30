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

/// 归档内的一个层级节点。`children == nil` 表示叶子（文件或空文件夹），
/// 直接喂给 SwiftUI 的 `List(_:children:)` 即可获得可折叠的目录树。
final class ArchiveNode: Identifiable {
    let path: String
    let name: String
    var size: Int64
    var isDirectory: Bool
    var children: [ArchiveNode]?

    init(path: String, name: String, size: Int64, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }

    var id: String { path }
}

enum ArchiveTree {
    /// 把扁平的路径列表组装成树。超过 `limit` 条时返回空数组，
    /// 由调用方回退到扁平列表，避免超大归档（十万级条目）拖慢界面。
    static func build(_ entries: [ArchiveEntry], limit: Int = 20_000) -> [ArchiveNode] {
        guard !entries.isEmpty, entries.count <= limit else { return [] }

        var map: [String: ArchiveNode] = [:]

        func normalize(_ raw: String) -> String {
            var path = raw
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/"), path.count > 1 { path.removeLast() }
            return path
        }

        func node(for path: String, isDirectory: Bool, size: Int64) -> ArchiveNode {
            if let existing = map[path] { return existing }
            let name = (path as NSString).lastPathComponent
            let created = ArchiveNode(path: path, name: name, size: size, isDirectory: isDirectory)
            map[path] = created
            return created
        }

        for entry in entries {
            let path = normalize(entry.path)
            guard !path.isEmpty, path != "." else { continue }
            let target = node(for: path, isDirectory: entry.isDirectory, size: entry.size)
            if entry.isDirectory {
                target.isDirectory = true
            } else {
                target.size = entry.size
            }
        }

        var roots: [ArchiveNode] = []
        for item in map.values {
            let parentPath = (item.path as NSString).deletingLastPathComponent
            if !parentPath.isEmpty, parentPath != item.path, let parent = map[parentPath] {
                parent.children = (parent.children ?? []) + [item]
            } else {
                roots.append(item)
            }
        }

        sort(&roots)
        return roots
    }

    private static func sort(_ nodes: inout [ArchiveNode]) {
        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for node in nodes {
            if var children = node.children {
                sort(&children)
                node.children = children
            }
        }
    }
}
