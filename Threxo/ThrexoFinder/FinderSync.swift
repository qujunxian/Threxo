import Cocoa
import FinderSync

/// 与主 App 相同的本地化约定：中文字面量直接作 key，缺失译文时回落到中文。
/// 扩展是独立 bundle，用的是自己 `Resources/<lang>.lproj/Localizable.strings`。
private func L(_ text: String) -> String {
    NSLocalizedString(text, comment: "")
}

/// Finder 右键扩展。
/// 产品约定：右键最多四项，按选中内容分工——
///   · 全是归档 → 「解压」+「解压到…」（一键解到当前目录 / 先挑目录）
///   · 其余情况 → 「压缩为 xxx」+「压缩为…」（按当前设置直接压 / 过一遍向导）
/// 点击后通过 `threxo://extract|extractTo|compress|compressDialog?path=...` 交给主 App。
class FinderSync: FIFinderSync {

    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "zst", "lz", "lzma", "cab", "iso", "jar", "war",
    ]

    /// 菜单构建时记下的选中项：点击时 FIFinderSyncController 的选中态可能已失效。
    private var pendingURLs: [URL] = []
    /// 清理 macOS 辅助文件只针对文件夹，单独记一份，避免和压缩项互相覆盖。
    private var pendingCleanFolders: [URL] = []

    override init() {
        super.init()
        // 兜底：主 App 启动时会做权威设置；此处保证扩展被单独加载时也能接管。
        // `/Volumes` 显式加上：外接盘、网络卷挂载后不一定被根目录的监视覆盖到。
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/Volumes"),
        ]
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

    override var toolbarItemName: String { L("千梭") }
    override var toolbarItemToolTip: String { L("用千梭解压或压缩") }
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
            pendingURLs = []
            pendingCleanFolders = []
            return menu
        }

        let archives = selected.filter { FinderSync.isArchive($0) }
        let allArchives = archives.count == selected.count

        // 第一项：不弹任何面板，按当前设置直接做。
        // 第二项：需要用户拍板（挑目录 / 选格式与密码）。
        if allArchives {
            let quickTitle = archives.count > 1
                ? String(format: L("用千梭解压 %d 个归档"), archives.count)
                : L("用千梭解压")
            menu.addItem(item(quickTitle, action: #selector(performQuickExtract(_:))))
            menu.addItem(item(L("用千梭解压到…"), action: #selector(performExtractTo(_:))))
            pendingURLs = archives
            pendingCleanFolders = []
        } else {
            // 普通文件、文件夹、以及混合选择都走压缩：任何内容都能打包。
            let quickTitle: String
            if selected.count > 1 {
                quickTitle = String(format: L("用千梭压缩 %d 项"), selected.count)
            } else {
                quickTitle = String(format: L("用千梭压缩「%@」"), FinderSync.stem(of: selected[0]))
            }
            menu.addItem(item(quickTitle, action: #selector(performQuickCompress(_:))))
            menu.addItem(item(L("用千梭压缩为…"), action: #selector(performCompressDialog(_:))))
            pendingURLs = selected

            // 选中项里有文件夹时，额外给一条「清理 macOS 辅助文件」：
            // 把 __MACOSX、.DS_Store、._* 这类跨系统传输的噪音一次清掉。
            let folders = selected.filter { FinderSync.isDirectory($0) }
            pendingCleanFolders = folders
            if !folders.isEmpty {
                let cleanTitle = folders.count > 1
                    ? String(format: L("用千梭清理 %d 个文件夹的 macOS 辅助文件"), folders.count)
                    : L("用千梭清理 macOS 辅助文件")
                menu.addItem(.separator())
                menu.addItem(item(cleanTitle, action: #selector(performCleanMacUtils(_:))))
            }
        }
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func performQuickExtract(_ sender: AnyObject?) { forward(host: "extract") }
    @objc private func performExtractTo(_ sender: AnyObject?) { forward(host: "extractTo") }
    @objc private func performQuickCompress(_ sender: AnyObject?) { forward(host: "compress") }
    @objc private func performCompressDialog(_ sender: AnyObject?) { forward(host: "compressDialog") }
    @objc private func performCleanMacUtils(_ sender: AnyObject?) {
        let folders = pendingCleanFolders
        pendingCleanFolders = []
        forward(host: "cleanmaceutils", urls: folders)
    }

    /// 优先用菜单构建时记下的那批：点击瞬间 `selectedItemURLs` 偶尔已经是空的。
    private func forward(host: String) {
        let urls = pendingURLs.isEmpty
            ? (FIFinderSyncController.default().selectedItemURLs() ?? [])
            : pendingURLs
        pendingURLs = []
        forward(host: host, urls: urls)
    }

    private func forward(host: String, urls: [URL]) {
        guard !urls.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "threxo"
        components.host = host
        components.queryItems = urls.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }

        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    /// 压缩产物的主干名：单个文件取去掉扩展名的名字，多选取所在目录名。
    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        let ext = url.pathExtension
        if !ext.isEmpty, name.count > ext.count + 1 {
            return String(name.dropLast(ext.count + 1))
        }
        return name
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    static func isArchive(_ url: URL) -> Bool {
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
