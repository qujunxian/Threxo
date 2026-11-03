import AppKit
import Foundation
import UniformTypeIdentifiers

/// 把归档里的条目「拖出去」到访达。
///
/// 拖拽开始时只登记意图，**真正落到访达时才解压**：否则拖一下 4GB 的包，
/// 得先等它解完才看见鼠标旁边有东西，体验更差。
enum ArchiveExport {
    enum ExportError: LocalizedError {
        case noArchive
        case failed(Int32)
        case missing

        var errorDescription: String? {
            switch self {
            case .noArchive: return L("没有正在打开的归档")
            case .failed(let code): return String(format: L("导出失败：%@"), AppModel.describe(exitCode: code))
            case .missing: return L("归档里没有找到这个条目")
            }
        }
    }

    /// 生成一份「丢给访达时再解压」的拖拽源。
    static func provider(
        name: String,
        isDirectory: Bool,
        archive: URL?,
        items: [String],
        pathInArchive: String,
        password: String?,
        executable: URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name

        // 目录必须声明成 public.folder，否则访达会当成一个普通文件去写，
        // 结果只得到一个打不开的空壳。
        let typeIdentifier = isDirectory ? UTType.folder.identifier : UTType.data.identifier

        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let archive else {
                    completion(nil, false, ExportError.noArchive)
                    return
                }
                do {
                    let url = try materialize(
                        archive: archive,
                        items: items,
                        pathInArchive: pathInArchive,
                        password: password,
                        executable: executable
                    )
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    /// 把条目解到临时目录，返回一个「名字与包内一致」的真实文件/文件夹。
    /// 导出的东西放在 `ThrexoExport-*` 里，由 `cleanupStale()` 定期收走。
    static func materialize(
        archive: URL,
        items: [String],
        pathInArchive: String,
        password: String?,
        executable: URL
    ) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("ThrexoExport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let runner = SevenZipRunner(executableURL: executable)
        var args = [
            "x", archive.path,
            "-o\(work.path)",
            "-y", "-aou", "-bso0", "-bsp0",
            "-p\(password ?? "")",
        ]
        args.append(contentsOf: items)

        let code = (try? runner.run(arguments: args)) ?? -1
        guard code == 0 else { throw ExportError.failed(code) }

        let path = normalize(pathInArchive)
        let source = work.appendingPathComponent(path)
        guard fm.fileExists(atPath: source.path) else { throw ExportError.missing }

        // 移到工作目录外面，这样清掉中间目录不会连带删掉要交给访达的文件。
        let out = fm.temporaryDirectory
            .appendingPathComponent("ThrexoDrop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let destination = out.appendingPathComponent((path as NSString).lastPathComponent)
        try fm.moveItem(at: source, to: destination)
        return destination
    }

    /// 清掉一天前的导出残留。拖到访达的东西是系统自己拷走的，
    /// 我们手里这份只是中转，放着不管会一直堆在 /tmp。
    static func cleanupStale() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            guard let items = try? fm.contentsOfDirectory(
                at: fm.temporaryDirectory,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else { return }

            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for url in items where url.lastPathComponent.hasPrefix("ThrexoExport-")
                || url.lastPathComponent.hasPrefix("ThrexoDrop-") {
                let modified = (try? url.resourceValues(forKeys: keys).contentModificationDate)
                    ?? Date.distantPast
                if modified < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    private static func normalize(_ raw: String) -> String {
        var path = raw
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
