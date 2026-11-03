import Foundation

/// 一条路径异常记录。
struct SafetyFinding: Sendable, Equatable {
    let path: String
    let problem: PathValidator.Problem
}

/// 解压链路的安全检查。
///
/// 7-Zip 26.04 实测会自己兜住路径穿越（`../a.txt` 落成 `a.txt`，
/// `/etc/a` 落成 `<目标>/etc/a`），所以这里的定位不是"挡住逃逸"，
/// 而是**把静默改写变成可见提示**，并在解压后复核目标目录外的写入。
enum ArchiveSafety {
    /// 只挑出真正要被解出的条目。`items` 为空表示整包。
    ///
    /// 给的是目录名时 7-Zip 会连带展开子项，所以用前缀匹配；
    /// 万一一支都没匹配上（名字对不上，比如带了尾斜杠），退回全量扫，宁可多查。
    static func inspect(entries: [ArchiveEntry], items: [String]) -> [SafetyFinding] {
        let scoped: [ArchiveEntry]
        if items.isEmpty {
            scoped = entries
        } else {
            let picked = entries.filter { entry in
                items.contains { item in
                    let base = item.hasSuffix("/") ? String(item.dropLast()) : item
                    return entry.path == base || entry.path.hasPrefix(base + "/")
                }
            }
            scoped = picked.isEmpty ? entries : picked
        }

        var findings: [SafetyFinding] = []
        var seen = Set<String>()
        for entry in scoped {
            guard let problem = PathValidator.problem(in: entry.path) else { continue }
            guard seen.insert(entry.path).inserted else { continue }
            findings.append(SafetyFinding(path: entry.path, problem: problem))
        }
        return findings
    }

    /// 解压前给目标目录拍个顶层快照，解压后用来算新增项。
    static func topLevelNames(of directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// 复核新增的顶层条目是否都还在 `root` 内（解符号链接后再比）。
    ///
    /// 只有在归档夹带符号链接、且解压器没重写链接目标时才可能命中。
    /// 命中说明有内容被写到了目标目录外，必须让用户知道。
    static func escaped(in root: URL, added names: Set<String>) -> [String] {
        names.filter { name in
            let candidate = root.appendingPathComponent(name)
            return !PathValidator.isInside(candidate, root: root)
        }.sorted()
    }

    /// 把检查结果拼成一句人话，`limit` 限制例举条数。
    static func summarize(_ findings: [SafetyFinding], limit: Int = 3) -> String {
        let grouped = Dictionary(grouping: findings, by: \.problem)
        let parts = PathValidator.Problem.allCases.compactMap { problem -> String? in
            guard let list = grouped[problem], !list.isEmpty else { return nil }
            return String(format: L("%@ %d 个"), problem.text, list.count)
        }
        var text = parts.joined(separator: L("、"))
        let samples = findings.prefix(limit).map(\.path)
        if !samples.isEmpty {
            text += "\n" + samples.map { "· \($0)" }.joined(separator: "\n")
            if findings.count > limit {
                text += "\n" + String(format: L("· 另有 %d 个未列出"), findings.count - limit)
            }
        }
        return text
    }
}
