import Foundation

/// 往**已有**归档里追加文件。
///
/// 7-Zip 没有「把文件塞进包内某个目录」这种开关——条目路径就是命令行上给的路径。
/// 所以做法是：在临时目录里搭一棵和目标层级一致的镜像，文件优先用硬链接（跨卷才复制），
/// 再把 `7zz a` 的工作目录设成镜像根、用**相对路径**追加，条目就会落在指定层级上。
enum ArchiveEditing {
    /// 搭好的镜像目录。`root` 用完要删，`relativePaths` 就是归档内的最终条目路径。
    struct Staged {
        let root: URL
        let relativePaths: [String]
        /// 本批条目的名字（不含目录），用于添加成功后回选。
        let names: [String]
    }

    /// 同名冲突时怎么处理。默认按钮永远给「保留两者」，覆盖是不可撤销的。
    enum ConflictPolicy {
        case overwrite
        case rename
        case cancel
    }

    /// 能原地追加条目的格式。
    /// gzip / bzip2 / xz 是单流压缩器，天然装不下第二个条目，追加只会毁掉原文件。
    static let appendableExtensions: Set<String> = ["zip", "jar", "war", "7z", "tar", "wim"]

    static func canAppend(to url: URL) -> Bool {
        appendableExtensions.contains(url.pathExtension.lowercased())
    }

    /// 在临时目录搭镜像。
    /// - Parameters:
    ///   - folder: 归档内的目标层级（空串表示根）。
    ///   - existingNames: 该层级里已存在的名字，用来判断冲突与取名。
    static func stage(
        _ urls: [URL],
        folder: String,
        policy: ConflictPolicy,
        existingNames: Set<String>
    ) throws -> Staged {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ThrexoAdd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var batch: Set<String> = []
        var relativePaths: [String] = []
        var names: [String] = []

        do {
            for url in urls {
                var name = url.lastPathComponent
                guard !name.isEmpty else { continue }

                // 同一批里重名必须错开，否则第二个会把第一个在镜像里覆盖掉；
                // 与归档内已有条目重名时，只有选了「保留两者」才改名。
                if batch.contains(name) || (existingNames.contains(name) && policy == .rename) {
                    var pool = existingNames.union(batch)
                    name = uniqueName(name, taken: &pool)
                }

                let relative = folder.isEmpty ? name : folder + "/" + name
                let dest = root.appendingPathComponent(relative)
                try fm.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try linkTree(url, to: dest)

                batch.insert(name)
                relativePaths.append(relative)
                names.append(name)
            }
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }

        return Staged(root: root, relativePaths: relativePaths, names: names)
    }

    /// `a.txt` 已占用时依次尝试 `a 2.txt`、`a 3.txt`…，并把这个名字记进 `taken`。
    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    /// 目录递归建树，文件优先硬链接：大目录零拷贝，跨卷才退回复制。
    private static func linkTree(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let values = try src.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

        // 符号链接连链接本身一起搬，别把目标整个拷进来。
        if values.isSymbolicLink == true {
            try fm.copyItem(at: src, to: dst)
            return
        }

        if values.isDirectory == true {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let children = try fm.contentsOfDirectory(
                at: src,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try linkTree(child, to: dst.appendingPathComponent(child.lastPathComponent))
            }
            return
        }

        do {
            try fm.linkItem(at: src, to: dst)
        } catch {
            try fm.copyItem(at: src, to: dst)
        }
    }
}
