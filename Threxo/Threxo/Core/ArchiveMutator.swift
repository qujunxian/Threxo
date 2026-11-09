import Foundation

/// 对已有归档做「原地修改」时的公共规则：能不能改、名字合不合法、失败怎么回滚。
///
/// 7zz 的 `d`（删除）与 `rn`（重命名）会直接改写原文件，中途失败可能留下半个包。
/// 所以任何修改前先把原包完整复制到临时目录，失败时整份还原。
enum ArchiveMutator {
    /// 能原地删除 / 重命名条目的格式。
    /// rar 只读；gz / bz2 / xz 是单流压缩器，装不下多个条目。
    static let editableExtensions: Set<String> = ["zip", "jar", "war", "7z", "tar", "wim"]

    /// 分卷包（`xxx.zip.001` 那一串）不能改：7zz 会拒绝，硬改会毁掉整组分卷。
    static func canEdit(_ archive: URL) -> Bool {
        let ext = archive.pathExtension.lowercased()
        guard editableExtensions.contains(ext) else { return false }
        return companionVolumes(for: archive).isEmpty
    }

    /// 与 archive 同主干的卷文件（`a.zip.001`、`a.zip.002`…）。
    static func companionVolumes(for archive: URL) -> [URL] {
        let fm = FileManager.default
        let dir = archive.deletingLastPathComponent()
        let prefix = archive.lastPathComponent + "."
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> URL? in
            guard name.hasPrefix(prefix) else { return nil }
            let suffix = name.dropFirst(prefix.count)
            guard suffix.count == 3, suffix.allSatisfy(\.isNumber) else { return nil }
            return dir.appendingPathComponent(name)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 改名前的校验。返回 nil 表示可用，否则是一句中文说明。
    /// - Parameters:
    ///   - siblings: 同一层级里已经存在的名字。
    ///   - original: 原来的名字（允许填回原名）。
    static func invalidReason(for name: String, siblings: Set<String>, original: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L("名字不能为空") }
        guard trimmed != "." && trimmed != ".." else { return L("这个名字不能用") }
        // 包内路径统一用 /，反斜杠、冒号、Windows 保留字符一律不收，
        // 免得在别的系统上解出来的路径被改写成别的层级。
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            return L("名字里不能带有 / \\ : * ? \" < > | 这些字符")
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return L("名字里不能带有控制字符")
        }
        guard trimmed == original || !siblings.contains(trimmed) else {
            return String(format: L("同一层级已经有「%@」"), trimmed)
        }
        return nil
    }

    /// 把原包复制到临时目录，返回备份路径。调用方负责在成功后删掉它。
    static func backup(_ archive: URL) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("ThrexoEdit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(archive.lastPathComponent)
        do {
            try fm.copyItem(at: archive, to: copy)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return copy
    }

    /// 修改失败时把备份整份还原回去，然后清掉临时目录。
    /// 返回值表示是否真的还原成功——失败时要让用户知道，不能装作没事。
    @discardableResult
    static func restore(_ archive: URL, from backup: URL) -> Bool {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: backup.deletingLastPathComponent()) }
        guard fm.fileExists(atPath: backup.path) else { return false }
        do {
            if fm.fileExists(atPath: archive.path) {
                try fm.removeItem(at: archive)
            }
            try fm.copyItem(at: backup, to: archive)
            return true
        } catch {
            // 还原也失败时把备份留在原地，用户至少还能手工捞回来。
            return false
        }
    }

    static func discard(_ backup: URL) {
        try? FileManager.default.removeItem(at: backup.deletingLastPathComponent())
    }
}
