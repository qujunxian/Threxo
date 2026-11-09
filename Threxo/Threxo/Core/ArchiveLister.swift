import Foundation

struct ArchiveEntry: Sendable {
    let path: String
    let size: Int64
    /// 压缩后占用的字节数。目录与「存储」方式的条目与 `size` 相同。
    let packedSize: Int64
    let modified: Date?
    let isDirectory: Bool

    /// 显示用的名字：扁平列表里是完整路径，树里由 `ArchiveNode.name` 负责。
    var displayName: String { (path as NSString).lastPathComponent }
}

enum ArchiveLister {
    /// `7zz -slt` 的时间形如 `2026-11-09 12:09:15.1920691`（本地时区）。
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // 去掉小数秒再解析，7zz 的小数位数不固定（0～7 位）。
        let head = raw.split(separator: ".").first.map(String.init) ?? raw
        return stampFormatter.date(from: head)
    }

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
            let packed = Int64(current["Packed Size"] ?? "0") ?? size
            result.append(ArchiveEntry(
                path: path,
                size: size,
                packedSize: packed,
                modified: parseDate(current["Modified"]),
                isDirectory: isDirectory
            ))
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

/// 列表排序依据。目录在任何排序下都排在最前，翻向只影响同类型之间的顺序。
enum ArchiveSortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case modified
    case packedSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return L("名称")
        case .size: return L("大小")
        case .modified: return L("修改时间")
        case .packedSize: return L("压缩后")
        }
    }
}

/// 归档内的一个层级节点。`children == nil` 表示叶子（文件或空文件夹），
/// 直接喂给 SwiftUI 的 `List(_:children:)` 即可获得可折叠的目录树。
final class ArchiveNode: Identifiable {
    let path: String
    let name: String
    var size: Int64
    var packedSize: Int64
    var modified: Date?
    var isDirectory: Bool
    var children: [ArchiveNode]?

    init(
        path: String,
        name: String,
        size: Int64,
        packedSize: Int64 = 0,
        modified: Date? = nil,
        isDirectory: Bool
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.isDirectory = isDirectory
    }

    var id: String { path }
}

enum ArchiveTree {
    /// 把扁平的路径列表组装成树。超过 `limit` 条时返回空数组，
    /// 由调用方回退到扁平列表，避免超大归档（十万级条目）拖慢界面。
    static func build(
        _ entries: [ArchiveEntry],
        sortKey: ArchiveSortKey = .name,
        ascending: Bool = true,
        limit: Int = 20_000
    ) -> [ArchiveNode] {
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
                target.packedSize = entry.packedSize
                target.modified = entry.modified
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

        sort(&roots, key: sortKey, ascending: ascending, limit: limit)
        return roots
    }

    /// 扁平列表（超大归档）也要能排序：先在条目层面排好，再交给界面。
    static func sortEntries(
        _ entries: [ArchiveEntry],
        key: ArchiveSortKey,
        ascending: Bool
    ) -> [ArchiveEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let result: Int
            switch key {
            case .name:
                result = compareStrings(lhs.path, rhs.path)
            case .size:
                result = compareNumbers(lhs.size, rhs.size)
            case .packedSize:
                result = compareNumbers(lhs.packedSize, rhs.packedSize)
            case .modified:
                let l = lhs.modified ?? .distantPast
                let r = rhs.modified ?? .distantPast
                result = l == r ? 0 : (l < r ? -1 : 1)
            }
            if result == 0 { return false }
            return ascending ? result < 0 : result > 0
        }
    }

    private static func compareStrings(_ lhs: String, _ rhs: String) -> Int {
        switch lhs.localizedStandardCompare(rhs) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static func compareNumbers(_ lhs: Int64, _ rhs: Int64) -> Int {
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }

    /// 树里每个层级的子项，供图标视图 / 分栏视图按路径取用。
    static func index(_ roots: [ArchiveNode]) -> [String: [ArchiveNode]] {
        var map: [String: [ArchiveNode]] = ["": roots]
        var stack = roots
        while let node = stack.popLast() {
            if let children = node.children {
                map[node.path] = children
                stack.append(contentsOf: children)
            }
        }
        return map
    }

    static func sort(
        _ nodes: inout [ArchiveNode],
        key: ArchiveSortKey,
        ascending: Bool,
        limit: Int = 20_000
    ) {
        // 超过 2 万条不建树也不排序：一次比较排序在十万级条目上要几百毫秒，滚动会被拖死。
        if nodes.count > limit {
            nodes.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return
        }
        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let result = compare(lhs, rhs, key: key)
            if result == 0 { return false }
            return ascending ? result < 0 : result > 0
        }
        for node in nodes {
            if var children = node.children {
                sort(&children, key: key, ascending: ascending, limit: limit)
                node.children = children
            }
        }
    }

    /// 同类型之间的比较结果：-1 表示 lhs 在前。
    static func compare(_ lhs: ArchiveNode, _ rhs: ArchiveNode, key: ArchiveSortKey) -> Int {
        switch key {
        case .name:
            // localizedStandardCompare 自带数字感知（file2 < file10），
            // 中文在 zh 环境下按拼音序，不会退化成码位排序。
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        case .size:
            if lhs.size == rhs.size { return tieBreak(lhs, rhs) }
            return lhs.size < rhs.size ? -1 : 1
        case .packedSize:
            if lhs.packedSize == rhs.packedSize { return tieBreak(lhs, rhs) }
            return lhs.packedSize < rhs.packedSize ? -1 : 1
        case .modified:
            let l = lhs.modified ?? .distantPast
            let r = rhs.modified ?? .distantPast
            if l == r { return tieBreak(lhs, rhs) }
            return l < r ? -1 : 1
        }
    }

    /// 数值相同时退回名称序，避免同尺寸条目每次刷新的顺序都在跳。
    private static func tieBreak(_ lhs: ArchiveNode, _ rhs: ArchiveNode) -> Int {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }
}
