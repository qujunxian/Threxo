import Cocoa
import FinderSync

/// Finder 右键扩展。
/// 产品约定：右键只出现一项——
///   · 选中的全是归档 → 「用千梭解压」
///   · 其余情况（普通文件 / 文件夹 / 混合） → 「用千梭压缩」
/// 点击后通过 `threxo://extract|compress?path=...` 交给主 App 处理。
class FinderSync: FIFinderSync {

    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "zst", "lz", "lzma", "cab", "iso", "jar", "war",
    ]

    /// 菜单构建时记录待执行动作；点击时 FIFinderSyncController 的选中态可能已失效。
    private enum Pending {
        case extract([URL])
        case compress([URL])

        var urls: [URL] {
            switch self {
            case .extract(let urls), .compress(let urls): return urls
            }
        }

        var host: String {
            switch self {
            case .extract: return "extract"
            case .compress: return "compress"
            }
        }
    }

    private var pending: Pending?

    override init() {
        super.init()
        // 兜底：主 App 启动时会做权威设置；此处保证扩展被单独加载时也能接管。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        // 诊断：确认扩展被加载、以及它实际监听的目录。
        FinderSync.dbg("init pid=\(getpid()) directoryURLs=\(FIFinderSyncController.default().directoryURLs.map(\.path)) isEnabled=\(FIFinderSyncController.isExtensionEnabled)")
    }

    // MARK: - Diagnosis

    /// 诊断日志，仅 Debug 构建生效，写入扩展沙盒容器：
    /// `~/Library/Containers/com.qujunxian.Threxo.Finder/Data/finder-debug.log`
    /// Release 构建下为 no-op，参数也不会被求值。
    static func dbg(_ message: @autoclosure () -> String) {
        #if DEBUG
        let path = NSHomeDirectory() + "/finder-debug.log"
        let line = "\(Date()) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        #endif
    }

    // MARK: - Toolbar

    override var toolbarItemName: String { "千梭" }
    override var toolbarItemToolTip: String { "用千梭解压或压缩" }
    override var toolbarItemImage: NSImage {
        NSImage(named: NSImage.folderName) ?? NSImage()
    }

    // MARK: - Context menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        // 容器空白处右键时 selectedItemURLs 为空，自然返回空菜单。
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        FinderSync.dbg("menu kind=\(menuKind.rawValue) targeted=\(FIFinderSyncController.default().targetedURL()?.path ?? "nil") selected=\(selected.count) \(selected.map(\.lastPathComponent))")
        guard !selected.isEmpty else {
            pending = nil
            return menu
        }

        let archives = selected.filter { FinderSync.isArchive($0) }

        let title: String
        if archives.count == selected.count {
            pending = .extract(archives)
            title = archives.count > 1 ? "用千梭解压 \(archives.count) 个归档" : "用千梭解压"
        } else {
            // 普通文件、文件夹、以及混合选择都走压缩：任何内容都能打包。
            pending = .compress(selected)
            title = selected.count > 1 ? "用千梭压缩 \(selected.count) 项" : "用千梭压缩"
        }

        let item = NSMenuItem(title: title, action: #selector(performPendingAction(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func performPendingAction(_ sender: AnyObject?) {
        guard let action = pending else { return }
        pending = nil

        var components = URLComponents()
        components.scheme = "threxo"
        components.host = action.host
        components.queryItems = action.urls.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }

        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private static func isArchive(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return true }
        // 处理 .tar.gz / .tar.bz2 这类双层扩展名
        let secondToLast = url.deletingPathExtension().pathExtension.lowercased()
        return secondToLast == "tar"
    }
}
