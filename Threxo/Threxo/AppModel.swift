import Foundation
import AppKit
import Combine
import FinderSync
import UniformTypeIdentifiers

/// 界面文案本地化入口（App 与界面层共用）。
///
/// 约定：**中文字面量直接作为 key**，`zh-Hans.lproj/Localizable.strings` 不需要条目，
/// 缺失译文时自动回落到中文原文，因此中文界面永远正确；只需在
/// `en.lproj/Localizable.strings` 里补英文即可。
/// 带参数时用 `String(format: L("… %@ …"), arg)`，key 与译文保持相同的占位符顺序。
func L(_ text: String) -> String {
    NSLocalizedString(text, comment: "")
}

/// UI-facing state and orchestration for the MVP flow:
/// open archive -> browse tree -> extract (all / selection) -> create zip.
///
/// 两条链路刻意分开：
///   · **界面链路**（双击归档、菜单、拖进窗口）：解到同级同名文件夹，可选位置，全部在窗口里反馈；
///   · **静默链路**（访达右键 `threxo://extract|compress`）：解压到压缩包所在文件夹、
///     压缩产物落在当前目录，不建主窗口、不弹位置选择，进度只在菜单栏显示。
final class AppModel: ObservableObject {
    /// 单例：AppDelegate 的 openFiles 回调需要一个稳定入口。
    static let shared = AppModel()

    @Published var archiveURL: URL?
    /// 当前归档的全部条目（未过滤）。筛选、排序都在这份原始数据上做，
    /// 这样切换「显示辅助项目」或改搜索词都不必重新读一遍归档。
    @Published private(set) var allEntries: [ArchiveEntry] = []
    /// 过滤 + 排序之后真正上屏的条目。
    @Published var entries: [ArchiveEntry] = []
    /// 层级树；条目过多时为空，界面回退到扁平列表。
    @Published var treeNodes: [ArchiveNode] = []
    /// 树中每个层级的子项，图标 / 分栏视图按路径取用。
    @Published private(set) var childrenIndex: [String: [ArchiveNode]] = [:]
    /// 选中的条目路径（与 ArchiveNode.id 一致）。
    @Published var selection: Set<String> = []

    /// 列表搜索词。`⌘F` 聚焦后实时过滤，同时按名字与包内路径匹配。
    @Published var searchText: String = "" {
        didSet { if oldValue != searchText { rebuildVisible() } }
    }

    /// 排序依据与方向，跟随 Finder 的习惯：点同一列头翻向，点新列头从升序开始。
    @Published var sortKey: ArchiveSortKey {
        didSet {
            guard oldValue != sortKey else { return }
            UserDefaults.standard.set(sortKey.rawValue, forKey: Self.sortKeyDefaultsKey)
            rebuildVisible()
        }
    }

    @Published var sortAscending: Bool {
        didSet {
            guard oldValue != sortAscending else { return }
            UserDefaults.standard.set(sortAscending, forKey: Self.sortAscendingDefaultsKey)
            rebuildVisible()
        }
    }

    /// 已按「显示辅助项目」过滤过的条目缓存，搜索时直接复用。
    private var baseEntries: [ArchiveEntry] = []
    private var baseDirty = true

    private static let sortKeyDefaultsKey = "threxo.browse.sortKey"
    private static let sortAscendingDefaultsKey = "threxo.browse.sortAscending"

    @Published var isBusy = false
    @Published var progress: Int = 0
    @Published var statusText = L("就绪")
    @Published var errorMessage: String?
    /// 当前正在处理的文件（来自 7zz -bb1 的进度行）。
    @Published var currentItem: String?

    /// 访达右键扩展是否已在「系统设置 → 登录项与扩展」里启用。
    /// 由 pkd 提供，状态可能滞后数秒，界面上提供手动刷新。
    @Published var finderExtensionEnabled = false

    /// 压缩设置（格式 / 级别 / 密码 / 排除 / 删源），与界面共享同一实例。
    let options = CompressionOptions.shared

    /// 解压加密归档时的密码框；非 nil 表示正在等用户输入。
    @Published var passwordPrompt: PasswordPrompt?

    /// 本次归档已确认可用的密码，只存在内存里，切换归档即清空。
    private var archivePassword: String?
    /// 归档是否含加密条目（来自 `l -slt` 的 `Encrypted = +`）。详情面板要用，所以要能观察。
    @Published private(set) var archiveEncrypted = false
    private var passwordContinuation: CheckedContinuation<String?, Never>?

    private var activeProcess: Process?
    private let runner: SevenZipRunner

    /// 压缩已完成但自检未通过时，这里存失败原因。
    /// 用它区分「压缩本身失败」和「文件写出来了但校验不过」——两者的
    /// 后续动作完全不同：后者绝不能删源文件，也不能把包当成可用产物。
    private var verifyFailure: String?

    /// 当前这轮任务跑在静默模式（访达右键）：没有主窗口可依附，
    /// 所以密码框、失败提示、完成后的跳转都必须走独立弹窗。
    private var silentRun = false

    /// 内置 7-Zip 不可用时的说明。非 nil 表示这台机器上没法处理压缩包，
    /// 界面据此显示提示并禁用操作——比 `fatalError` 直接闪退好交代。
    @Published private(set) var startupError: String?

    /// 解压时发现的非致命路径异常（`../` 被落平），成功后拼进结果提示。
    private var pendingSafetyNote: String?

    /// 安全检查拦下解压时的详细说明。写成属性是因为静默链路的通知
    /// 由任务收尾统一发一次，中途再发一条就成了重复打扰。
    private var pendingSafetyFailure: String?

    /// 自定义退出码：路径安全检查未通过。
    static let exitUnsafePath: Int32 = 254

    struct PasswordPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        // 排序偏好跨会话记忆；放在最前面是因为下面的 rebuild 会读它。
        let rawKey = UserDefaults.standard.string(forKey: Self.sortKeyDefaultsKey)
        sortKey = rawKey.flatMap(ArchiveSortKey.init(rawValue:)) ?? .name
        sortAscending = UserDefaults.standard.object(forKey: Self.sortAscendingDefaultsKey) as? Bool ?? true

        // 缺资源时不崩：指向一个必然不存在的路径，让 `Process.run()` 抛错走正常失败分支。
        let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil)
        runner = SevenZipRunner(executableURL: bundled ?? URL(fileURLWithPath: "/nonexistent/7zz"))
        if bundled == nil || !FileManager.default.isExecutableFile(atPath: bundled!.path) {
            startupError = L("应用内缺少 7-Zip 程序（Resources/7zz），无法处理压缩包。请重新下载安装包。")
            appDbg("7zz missing")
        }
        refreshFinderExtensionState()
        ArchiveExport.cleanupStale()

        // 设置里的「显示辅助项目」开关一改，列表立刻跟着变，不用重开归档。
        SettingsStore.shared.$showAuxiliaryItems
            .dropFirst()
            .sink { [weak self] _ in
                self?.baseDirty = true
                self?.rebuildVisible()
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Derived state

    /// 头部与详情面板都按「整个归档」统计，不受搜索与辅助项目开关影响。
    var totalUncompressedSize: Int64 {
        allEntries.reduce(0) { $0 + $1.size }
    }

    var fileCount: Int {
        allEntries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
    }

    /// 归档里一共有多少条目（含目录）。
    var entryCount: Int { allEntries.count }

    var hasSelection: Bool { !selection.isEmpty }

    /// 压缩包自身在磁盘上的大小。
    var archiveByteSize: Int64 {
        guard let url = archiveURL else { return 0 }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    var archiveModified: Date? {
        guard let url = archiveURL else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    var isArchiveEncrypted: Bool { archiveEncrypted }

    /// 单选时详情面板显示这一项，多选或未选显示整个归档。
    var detailEntry: ArchiveEntry? {
        guard selection.count == 1, let path = selection.first else { return nil }
        return allEntries.first { $0.path == path || Self.normalizeEntryPath($0.path) == path }
    }

    /// 详情面板顶部的类型名，例如「ZIP 压缩包」「TAR.GZ 压缩包」。
    var archiveTypeName: String {
        guard let url = archiveURL else { return L("未打开归档") }
        return Self.typeName(for: url)
    }

    static func typeName(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let table: [(String, String)] = [
            (".tar.gz", "TAR.GZ 压缩包"), (".tar.bz2", "TAR.BZ2 压缩包"),
            (".tar.xz", "TAR.XZ 压缩包"), (".tar.zst", "TAR.ZST 压缩包"),
            (".tgz", "TGZ 压缩包"), (".tbz2", "TBZ2 压缩包"), (".tbz", "TBZ 压缩包"),
            (".txz", "TXZ 压缩包"), (".zipx", "ZIPX 压缩包"), (".zip", "ZIP 压缩包"),
            (".7z", "7Z 压缩包"), (".rar", "RAR 压缩包"), (".jar", "JAR 压缩包"),
            (".war", "WAR 归档"), (".tar", "TAR 归档"), (".gz", "GZIP 压缩包"),
            (".bz2", "BZIP2 压缩包"), (".xz", "XZ 压缩包"), (".lzma", "LZMA 压缩包"),
            (".cab", "CAB 压缩包"), (".iso", "ISO 镜像"), (".dmg", "DMG 镜像"),
            (".wim", "WIM 镜像"), (".xar", "XAR 归档"), (".pkg", "PKG 安装包"),
        ]
        for (suffix, title) in table where name.hasSuffix(suffix) {
            return L(title)
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? L("归档") : String(format: L("%@ 压缩包"), ext)
    }

    // MARK: - Finder extension

    /// 重新向系统查询扩展启用状态。
    func refreshFinderExtensionState() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        if enabled != finderExtensionEnabled {
            finderExtensionEnabled = enabled
        }
    }

    /// 打开「系统设置 → 通用 → 登录项与扩展」。
    func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Open / list

    func openArchive() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("panel.openArchive.message", comment: "打开归档面板的提示语")
        panel.prompt = NSLocalizedString("panel.openArchive.prompt", comment: "打开归档面板的确认按钮")
        panel.allowedContentTypes = Self.archiveTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(archive: url)
    }

    func load(archive url: URL) {
        isBusy = true
        progress = 0
        errorMessage = nil
        currentItem = nil
        archiveURL = url
        allEntries = []
        entries = []
        treeNodes = []
        childrenIndex = [:]
        selection = []
        searchText = ""
        archivePassword = nil
        archiveEncrypted = false
        statusText = L("正在读取归档…")

        Task { @MainActor in
            var password: String?
            var attempt = 0
            var cancelled = false
            var result = await list(url, password: nil)

            // 头部加密的 7z、以及带密码的 zip，连列目录都会失败；
            // 这里先索要密码再重试，最多三轮，避免用户误输入后死循环。
            while result.code != 0, Self.isPasswordError(result.error), attempt < 3 {
                attempt += 1
                guard let entered = await self.askPassword(isRetry: attempt > 1) else {
                    cancelled = true
                    break
                }
                password = entered
                result = await list(url, password: entered)
            }

            self.finishLoading(url: url, result: result, password: password, cancelled: cancelled)
        }
    }

    /// 列归档。始终带 `-p`（空值），否则 7zz 会停下来等终端输入密码，进程直接卡住。
    private func list(_ url: URL, password: String?) async -> (code: Int32, output: String, error: String) {
        await runSync(["l", "-slt", "-ba", "-p\(password ?? "")", url.path])
    }

    private func finishLoading(
        url: URL,
        result: (code: Int32, output: String, error: String),
        password: String?,
        cancelled: Bool
    ) {
        isBusy = false
        if cancelled && result.code != 0 {
            statusText = L("已取消")
            return
        }
        guard result.code == 0 else {
            errorMessage = String(format: L("读取归档失败：%@"), Self.describe(exitCode: result.code))
            statusText = L("读取失败")
            return
        }
        archivePassword = password
        archiveEncrypted = result.output.contains("Encrypted = +")
        allEntries = ArchiveLister.parse(result.output)
        baseDirty = true
        rebuildVisible()
        let files = entries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
        statusText = String(format: L("已加载 %@ · %d 个文件"), url.lastPathComponent, files)
    }

    /// 把 `allEntries` 按当前开关与搜索词筛一遍，再重新建树。
    /// 原始条目留在 `allEntries` 里，所以来回切开关不会丢东西，也不用重读归档。
    private func rebuildVisible() {
        #if DEBUG
        let started = Date()
        defer {
            appDbg(String(
                format: "rebuild q=%@ entries=%d tree=%d %.1fms",
                searchText, entries.count, treeNodes.count,
                Date().timeIntervalSince(started) * 1000
            ))
        }
        #endif

        // 辅助文件过滤只跟「原始条目」和那个开关有关，没必要每次敲键都重算。
        // 5 万条上一次约 150ms（Debug 构建），逐字搜索会被它拖垮。
        if baseDirty {
            baseEntries = SettingsStore.shared.showAuxiliaryItems
                ? allEntries
                : allEntries.filter { !Self.isAuxiliaryPath($0.path) }
            baseDirty = false
        }

        var visible = baseEntries
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // 5 万条实测：整串 `range(of:)` 要 110～140ms，先 lowercase 再 contains 约 35ms。
            // 搜索是逐字触发的，这 100ms 直接决定「打字跟不跟手」。
            visible = visible.filter { $0.path.lowercased().contains(query) }
        }

        entries = ArchiveTree.sortEntries(visible, key: sortKey, ascending: sortAscending)
        treeNodes = ArchiveTree.build(entries, sortKey: sortKey, ascending: sortAscending)
        childrenIndex = ArchiveTree.index(treeNodes)
        // 过滤之后不在列表里的选中项要摘掉，否则「解压所选」会解到看不见的东西。
        if !selection.isEmpty {
            let alive = Set(visible.map(\.path))
            selection = selection.filter { alive.contains($0) }
        }
    }

    /// 逐段 `split` 在 5 万条上要 80ms 上下，而这段代码每次搜索都会跑一遍。
    /// 改成一串 `hasSuffix` / `contains`：不做数组分配，实测降到个位数毫秒。
    private static func isAuxiliaryPath(_ raw: String) -> Bool {
        if raw.hasSuffix("/.DS_Store") || raw == ".DS_Store" { return true }
        if raw.hasSuffix("/Thumbs.db") || raw == "Thumbs.db" { return true }
        if raw.hasSuffix("/desktop.ini") || raw == "desktop.ini" { return true }
        if let slash = raw.lastIndex(of: "/") {
            if raw[raw.index(after: slash)...].hasPrefix("._") { return true }
        } else if raw.hasPrefix("._") {
            return true
        }
        return raw.contains("__MACOSX") || raw.contains(".fseventsd")
            || raw.contains(".Trashes") || raw.contains(".background")
    }

    /// 双击归档 / 拖到 Dock 图标 / 「打开方式」都会走到这里。
    func receiveOpenFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let archives = urls.filter { Self.isArchiveURL($0) }
        if let first = archives.first {
            load(archive: first)
        } else {
            // 非归档（文件夹、普通文件）→ 按右键菜单同样的语义：压缩。
            compressAutomatically(urls)
        }
    }

    // MARK: - Extract (UI flows)

    /// 一键解压：位置跟随设置。默认解到归档同级的新文件夹，重名自动加序号。
    func extractAll() {
        guard !isBusy, let archive = archiveURL else { return }
        guard let dest = extractionDestination(for: archive) else { return }
        extract(archive: archive, to: dest, items: [], status: L("正在解压…"), reveal: true)
    }

    /// 按设置决定「解压」按钮落到哪里。
    /// 默认仍然解到同级的新文件夹——直接铺在源目录旁边，同名文件一多就分不清哪些是刚解出来的。
    private func extractionDestination(for archive: URL) -> URL? {
        switch SettingsStore.shared.extractionTarget {
        case .archiveFolder:
            return uniqueExtractDestination(for: archive)

        case .lastUsed:
            let dir = SettingsStore.shared.lastExtractDirectory ?? archive.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir

        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = NSLocalizedString("panel.extractTo.message", comment: "选择解压目标文件夹的提示语")
            panel.prompt = NSLocalizedString("panel.extractTo.prompt", comment: "解压目标面板的确认按钮")
            panel.directoryURL = SettingsStore.shared.lastExtractDirectory
                ?? archive.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
            SettingsStore.shared.lastExtractDirectory = chosen
            return chosen
        }
    }

    /// 手动选择解压位置。
    func extractAllChoosingDestination() {
        guard !isBusy, let archive = archiveURL else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("panel.extractTo.message", comment: "选择解压目标文件夹的提示语")
        panel.prompt = NSLocalizedString("panel.extractTo.prompt", comment: "解压目标面板的确认按钮")
        panel.directoryURL = archive.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        extract(archive: archive, to: dest, items: [], status: L("正在解压…"), reveal: true)
    }

    /// 右键某一行时要处理的范围：这一行在多选里就整批处理，否则只处理这一行。
    func targets(for path: String) -> [String] {
        selection.contains(path) ? Array(selection) : [path]
    }

    /// 工具栏「解压到…」：有选中就只解选中的，没选中解全部。
    func extractChoosingDestination() {
        if hasSelection {
            extractPaths(Array(selection), choosingDestination: true)
        } else {
            extractAllChoosingDestination()
        }
    }

    /// 把指定条目解到用户挑的目录（保留包内相对路径）。
    func extractPaths(_ paths: [String], choosingDestination: Bool) {
        guard !isBusy, let archive = archiveURL else { return }
        let items = expandSelection(Set(paths))
        guard !items.isEmpty else { return }

        let dest: URL
        if choosingDestination {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = NSLocalizedString("panel.extractTo.message", comment: "选择解压目标文件夹的提示语")
            panel.prompt = NSLocalizedString("panel.extractTo.prompt", comment: "解压目标面板的确认按钮")
            panel.directoryURL = archive.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            dest = chosen
        } else {
            // 「解到压缩包所在文件夹」：直接铺在原地，重名自动改名，绝不覆盖。
            dest = archive.deletingLastPathComponent()
        }

        extract(
            archive: archive,
            to: dest,
            items: items,
            status: String(format: L("正在解压所选的 %d 个文件…"), items.count),
            reveal: true
        )
    }

    /// 只解压选中的条目（选中的文件夹会自动展开为其中的文件）。
    func extractSelected() {
        guard !isBusy, let archive = archiveURL, !selection.isEmpty else { return }
        let items = expandSelection(selection)
        guard !items.isEmpty else { return }
        let dest = uniqueExtractDestination(for: archive)
        extract(
            archive: archive,
            to: dest,
            items: items,
            status: String(format: L("正在解压所选的 %d 个文件…"), items.count),
            reveal: true
        )
    }

    /// 解到「压缩包同级的同名文件夹」，重名就换下一个名字——与主按钮同一套语义。
    func extractPathsToNewFolder(_ paths: [String]) {
        guard !isBusy, let archive = archiveURL else { return }
        let items = expandSelection(Set(paths))
        guard !items.isEmpty else { return }
        let dest = uniqueExtractDestination(for: archive)
        extract(
            archive: archive,
            to: dest,
            items: items,
            status: String(format: L("正在解压所选的 %d 个文件…"), items.count),
            reveal: true
        )
    }

    private func extract(
        archive: URL,
        to dest: URL,
        items: [String],
        status: String,
        reveal: Bool
    ) {
        // 重名策略以设置为准：界面上的调用点只在「解到压缩包所在文件夹」时传 true，
        // 其余都是解到新建的空文件夹，本来就不会撞名。
        let rename: Bool
        switch SettingsStore.shared.conflictPolicy {
        case .rename:
            rename = true
        case .overwrite:
            guard confirmOverwrite(to: dest) else { return }
            rename = false
        case .ask:
            switch resolveConflict(to: dest) {
            case .cancel: return
            case .rename: rename = true
            case .overwrite: rename = false
            }
        }

        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        runTask(status: status) { [self] in
            await extractBlocking(archive: archive, to: dest, items: items, renameExisting: rename)
        } completion: { code in
            if code == 0 {
                self.progress = 100  // 7zz 不保证打到 100%，成功后补齐。
                self.currentItem = nil
                var text = String(format: L("解压完成 → %@"), dest.path)
                if let note = self.pendingSafetyNote {
                    text += "（\(note)）"
                    self.pendingSafetyNote = nil
                }
                self.statusText = text
                if reveal, SettingsStore.shared.revealAfterExtract {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
                self.applyArchiveHandling(archive: archive)
                if SettingsStore.shared.closeAfterExtract, self.archiveURL == archive {
                    self.unloadArchive()
                    MainWindowController.shared.close()
                }
            } else {
                self.statusText = code == 255 ? L("已取消") : L("解压失败")
                if code != 255 {
                    self.errorMessage = Self.describe(exitCode: code)
                }
            }
        }
    }

    // MARK: - 重名与后处理

    private enum ConflictChoice {
        case rename
        case overwrite
        case cancel
    }

    /// 顶层条目名，用来判断「这次解出来的会不会撞上已有的东西」。
    private func archiveTopLevelNames() -> Set<String> {
        var names: Set<String> = []
        for entry in entries {
            let path = Self.normalizeEntryPath(entry.path)
            guard let first = path.split(separator: "/").first else { continue }
            names.insert(String(first))
        }
        return names
    }

    private func resolveConflict(to dest: URL) -> ConflictChoice {
        let existing = Set(ArchiveSafety.topLevelNames(of: dest))
        guard !existing.isEmpty else { return .rename }

        let clashes = existing.intersection(archiveTopLevelNames())
        guard !clashes.isEmpty else { return .rename }

        let sample = clashes.sorted().prefix(3).joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = L("目标文件夹里已有同名内容")
        alert.informativeText = String(
            format: L("「%@」等 %d 项已经存在。自动改名会保留两份，覆盖会替换掉原文件。"),
            sample, clashes.count
        )
        alert.addButton(withTitle: L("自动改名"))
        alert.addButton(withTitle: L("覆盖"))
        alert.addButton(withTitle: L("取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .rename
        case .alertSecondButtonReturn: return .overwrite
        default: return .cancel
        }
    }

    /// 覆盖是破坏性的，即使设置里选了「覆盖」，每次动手前也再确认一次。
    private func confirmOverwrite(to dest: URL) -> Bool {
        guard !ArchiveSafety.topLevelNames(of: dest).isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("将覆盖目标文件夹里的同名文件")
        alert.informativeText = String(format: L("解压目标：%@"), dest.path)
        alert.addButton(withTitle: L("覆盖"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 解压成功后按设置处理源压缩包。静默链路不走这里——右键解压后删掉源包没人会同意。
    private func applyArchiveHandling(archive: URL) {
        let handling = SettingsStore.shared.archiveHandling
        guard handling != .keep else { return }

        if handling == .ask {
            let alert = NSAlert()
            alert.messageText = L("压缩包要保留吗？")
            alert.informativeText = String(format: L("「%@」可以移入废纸篓，需要时从废纸篓放回即可。"), archive.lastPathComponent)
            alert.addButton(withTitle: L("保留"))
            alert.addButton(withTitle: L("移入废纸篓"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }

        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: archive, resultingItemURL: &resulting)
        } catch {
            errorMessage = String(format: L("移到废纸篓失败：%@"), error.localizedDescription)
        }
    }

    /// 清空当前归档状态（源包被移走或关闭窗口时用）。
    private func unloadArchive() {
        archiveURL = nil
        entries = []
        treeNodes = []
        selection = []
        archivePassword = nil
        archiveEncrypted = false
    }

    /// 访达右键：逐个解压到**压缩包所在文件夹**（右键时的那个「当前目录」）。
    /// 不建窗口、不弹位置选择；已有同名文件由 `-aou` 自动改名，绝不静默覆盖。
    func extractAutomatically(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isBusy else { NSSound.beep(); return }

        let archives = urls
        // 静默任务和「当前打开的归档」无关，清掉上一份归档的密码状态，
        // 否则会给没加密的包白弹一次密码框。
        archivePassword = nil
        archiveEncrypted = false
        let silent = beginSilentRun()

        runTask(status: L("正在解压…")) { [self] in
            var lastCode: Int32 = 0
            for (index, archive) in archives.enumerated() {
                await MainActor.run {
                    self.statusText = archives.count > 1
                        ? String(format: L("正在解压 (%d/%d)…"), index + 1, archives.count)
                        : L("正在解压…")
                }
                // 当前目录 = 压缩包所在目录：内容直接铺在这里，不再多套一层同名文件夹。
                let dest = archive.deletingLastPathComponent()
                lastCode = await extractBlocking(
                    archive: archive,
                    to: dest,
                    items: [],
                    renameExisting: true,
                    silent: silent
                )
                if lastCode != 0 { break }
            }
            return lastCode
        } completion: { code in
            defer { if silent { self.endSilentRun() } }

            if code == 0 {
                self.progress = 100
                self.currentItem = nil
                let folder = archives[0].deletingLastPathComponent()
                self.statusText = archives.count > 1
                    ? String(format: L("已解压 %d 个归档到当前文件夹"), archives.count)
                    : L("解压完成，文件已放到当前文件夹")
                if silent {
                    var body = String(format: L("已解压到「%@」"), folder.lastPathComponent)
                    if let note = self.pendingSafetyNote {
                        body += "\n" + note
                        self.pendingSafetyNote = nil
                    }
                    Notifier.shared.success(
                        title: archives.count > 1
                            ? String(format: L("已解压 %d 个归档"), archives.count)
                            : L("解压完成"),
                        body: body,
                        reveal: folder
                    )
                }
            } else {
                self.statusText = code == 255 ? L("已取消") : L("解压失败")
                guard code != 255 else { return }
                let detail = Self.describe(exitCode: code)
                let safety = self.pendingSafetyFailure
                self.pendingSafetyFailure = nil
                if silent {
                    self.reportSilentFailure(
                        title: safety != nil ? L("解压已停止") : L("解压失败"),
                        message: safety ?? detail,
                        lines: safety != nil ? 3 : 1
                    )
                } else {
                    self.errorMessage = safety ?? detail
                }
            }
        }
    }

    // MARK: - 追加文件到归档（把访达里的文件拖进来）

    /// 把 `urls` 加进当前归档的 `folder` 层级（nil / 空串表示根）。
    ///
    /// 7-Zip 没有「放进包内某目录」的参数，条目路径就是命令行给的路径，
    /// 所以这里先在临时目录搭一棵镜像，再用相对路径追加（见 `ArchiveEditing`）。
    func addDroppedFiles(_ urls: [URL], toFolder folder: String?) {
        guard !urls.isEmpty else { return }
        guard let archive = archiveURL else {
            // 没开归档时，拖进来的东西按原语义处理：归档就打开、其他就压缩。
            receiveOpenFiles(urls)
            return
        }
        guard !isBusy else { NSSound.beep(); return }
        guard ArchiveEditing.canAppend(to: archive) else {
            errorMessage = String(
                format: L("「%@」这种格式装不下多个条目，无法直接追加文件。请先解压再重新打包。"),
                archive.pathExtension.uppercased()
            )
            return
        }

        let target = Self.normalizeEntryPath(folder ?? "")
        let existing = childNames(in: target)
        let incoming = urls.map(\.lastPathComponent)
        let conflicts = incoming.filter(existing.contains)

        var policy = ArchiveEditing.ConflictPolicy.overwrite
        if !conflicts.isEmpty {
            policy = askAppendConflict(conflicts)
            guard policy != .cancel else { return }
        }

        let staged: ArchiveEditing.Staged
        do {
            staged = try ArchiveEditing.stage(
                urls,
                folder: target,
                policy: policy,
                existingNames: existing
            )
        } catch {
            errorMessage = String(format: L("准备要添加的文件失败：%@"), error.localizedDescription)
            return
        }
        guard !staged.relativePaths.isEmpty else {
            try? FileManager.default.removeItem(at: staged.root)
            return
        }

        let location = target.isEmpty ? archive.lastPathComponent : target
        appDbg("addDroppedFiles folder=\(target) staged=\(staged.relativePaths)")

        runTask(status: L("正在添加文件…")) { [self] in
            // 往加密包里追加同样要密码，而且必须在起进程前拿到，
            // 否则 7zz 会退化成「用空密码新写一个不加密的条目」。
            if archiveEncrypted, archivePassword == nil {
                guard let entered = await askPassword(isRetry: false) else { return 255 }
                archivePassword = entered
            }
            return await runAdd(
                archive: archive,
                relativePaths: staged.relativePaths,
                staging: staged.root
            )
        } completion: { code in
            try? FileManager.default.removeItem(at: staged.root)
            appDbg("add finished code=\(code)")

            if code == 0 {
                self.progress = 100
                self.currentItem = nil
                self.statusText = String(
                    format: L("已添加 %d 项 → %@"),
                    staged.relativePaths.count,
                    location
                )
                self.reloadEntries(selecting: staged.relativePaths)
            } else {
                self.statusText = code == 255 ? L("已取消") : L("添加失败")
                if code != 255 { self.errorMessage = Self.describe(exitCode: code) }
            }
        }
    }

    /// 同名条目已经在归档里：给的是「保留两者 / 覆盖 / 取消」，默认按钮是最安全的那个。
    private func askAppendConflict(_ names: [String]) -> ArchiveEditing.ConflictPolicy {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? String(format: L("归档里已经有「%@」"), names[0])
            : String(format: L("归档里已有 %d 个同名项目"), names.count)
        alert.informativeText = L("覆盖会替换归档里的旧内容，且无法撤销。")
        alert.addButton(withTitle: L("保留两者"))
        alert.addButton(withTitle: L("覆盖"))
        alert.addButton(withTitle: L("取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .rename
        case .alertSecondButtonReturn: return .overwrite
        default: return .cancel
        }
    }

    /// 某个层级下已存在的条目名（只看直属子项，不含更深层）。
    private func childNames(in folder: String) -> Set<String> {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var names: Set<String> = []
        for entry in entries {
            let path = Self.normalizeEntryPath(entry.path)
            guard path.count > prefix.count, path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            guard !rest.contains("/") else { continue }
            names.insert(String(rest))
        }
        return names
    }

    private func runAdd(archive: URL, relativePaths: [String], staging: URL) async -> Int32 {
        var args = ["a", archive.path, "-y", "-bsp1", "-bb1"]
        // 注意：`a` 上的空 `-p` 不等于「不加密」，而是「去问用户要密码」，
        // 没有终端时会一直挂着。所以这儿只在真有密码时才带这个参数。
        if let password = archivePassword, !password.isEmpty {
            args.append("-p\(password)")
            // 往加密的 zip 里追加：不显式指定 AES 的话，新条目会退化成 ZipCrypto，
            // 同一个包里混两种加密方式，别的解压工具很容易打不开。
            if archiveEncrypted, archive.pathExtension.lowercased() == "zip" {
                args.append("-mem=AES256")
            }
        }
        args.append(contentsOf: relativePaths)
        return await runWithProgress(args, workingDirectory: staging, progressRange: 0...100)
    }

    /// 追加成功后重新读一遍归档，并把新条目选上，省得用户自己找。
    private func reloadEntries(selecting paths: [String]) {
        guard let archive = archiveURL else { return }
        let password = archivePassword
        Task { @MainActor in
            let result = await self.list(archive, password: password)
            guard result.code == 0 else {
                self.errorMessage = String(format: L("读取归档失败：%@"), Self.describe(exitCode: result.code))
                return
            }
            let parsed = ArchiveLister.parse(result.output)
            self.entries = parsed
            self.treeNodes = ArchiveTree.build(parsed)
            let available = Set(parsed.map { Self.normalizeEntryPath($0.path) })
            let wanted = paths.map(Self.normalizeEntryPath).filter(available.contains)
            if !wanted.isEmpty { self.selection = Set(wanted) }
        }
    }

    // MARK: - 拖出到访达（解压到拖到的位置）

    /// 生成拖拽源：真正落到访达时才解压，拖拽预览下不发一次多余的解压。
    /// 拖文件夹时会把整个子树一起带出去。
    func dragProvider(path: String, name: String, isDirectory: Bool) -> NSItemProvider {
        let normalized = Self.normalizeEntryPath(path)
        var items = [normalized]
        if isDirectory {
            let prefix = normalized + "/"
            items.append(contentsOf: entries
                .map { Self.normalizeEntryPath($0.path) }
                .filter { $0.hasPrefix(prefix) })
        }
        return ArchiveExport.provider(
            name: name,
            isDirectory: isDirectory,
            archive: archiveURL,
            items: items,
            pathInArchive: normalized,
            password: archivePassword,
            executable: runner.executableURL
        )
    }

    // MARK: - Compress (UI flow)

    func compress() {
        guard !isBusy else { return }

        if let mismatch = options.passwordValidationMessage {
            errorMessage = mismatch
            return
        }

        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.message = NSLocalizedString("panel.compress.select.message", comment: "选择待压缩内容的提示语")
        open.prompt = NSLocalizedString("panel.compress.select.prompt", comment: "选择待压缩内容面板的确认按钮")
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let sources = open.urls

        let save = NSSavePanel()
        // 默认文件名跟着格式走：选 GZIP 就是 abc.tar.gz，不会出现 a.zip 里装 gzip 的错配。
        save.nameFieldStringValue = "\(Self.defaultArchiveBase(for: sources)).\(options.format.fileExtension)"
        save.message = NSLocalizedString("panel.compress.save.message", comment: "压缩保存面板的提示语")
        save.prompt = NSLocalizedString("panel.compress.save.prompt", comment: "压缩保存面板的确认按钮")
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let chosen = save.url else { return }

        // 保存面板里可能被改成不带后缀的名字，补回来，保证产物能被正常识别。
        let suffix = "." + options.format.fileExtension
        let dest = chosen.path.hasSuffix(suffix)
            ? chosen
            : URL(fileURLWithPath: chosen.path + suffix)

        compress(sources: sources, to: dest)
    }

    /// 访达右键：用当前设置把项目压到第一个项目所在目录（右键时的「当前目录」）。
    /// 不覆盖已有归档：同名时自动追加序号（a.zip → a 2.zip），避免静默丢数据。
    func compressAutomatically(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isBusy else { NSSound.beep(); return }
        let dir = urls[0].deletingLastPathComponent()
        let base = Self.defaultArchiveBase(for: urls)
        let ext = options.format.fileExtension

        var dest = dir.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        // 分卷包的第一卷是 `xxx.zip.001`，主文件名本身不存在，得连卷一起查，
        // 否则会撞上上一次留下的同名卷包。
        while FileManager.default.fileExists(atPath: dest.path)
            || !Self.volumeSet(for: dest).isEmpty {
            dest = dir.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        compress(sources: urls, to: dest, silent: beginSilentRun())
    }

    private func compress(sources: [URL], to dest: URL, silent: Bool = false) {
        // 勾了「压缩完成后删源文件」时先确认一次，默认按钮是取消。
        // 静默任务不确认也不删——访达右键的约定是「不弹任何框」，
        // 而删源不可逆，宁可不删，把结果写在通知里。
        let deleteSource = options.deleteSourceAfterCompress && !silent
        guard silent || confirmSourceRemovalIfNeeded(sources: sources) else {
            return
        }

        let volumeMode = options.format.supportsVolume
            && options.volumeSize.megabytes(custom: options.customVolumeMB) != nil
        let oldVolumes = volumeMode ? Self.volumeSet(for: dest) : []

        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        } else if !oldVolumes.isEmpty {
            // 同名旧卷包还在（xxx.zip.001 …）：必须先问一句再删。
            // 静默链路不弹框（访达右键的约定），此时直接放弃并提示，让用户自己改名。
            if silent {
                reportSilentFailure(
                    title: L("目标位置已有同名分卷包"),
                    message: String(format: L("「%@」已存在。请换个名字，或先在主窗口里重压一次。"),
                                    oldVolumes[0].lastPathComponent)
                )
                endSilentRun()
                return
            }
            guard confirmReplacingVolumeSet(oldVolumes) else { return }
            Self.removeVolumeSet(for: dest)
        }

        let verify = options.verifyAfterCompress
        verifyFailure = nil
        // 开了自检就把压缩阶段收在 0-90，最后 10 留给校验，
        // 否则进度条已经冲到 100 还在跑，看起来像卡住了。
        let compressCap = verify ? 90 : 100

        runTask(status: L("正在压缩…")) { [self] in
            let code = await compressBlocking(
                sources: sources,
                to: dest,
                progressCap: compressCap,
                // 右键静默压缩不分卷：分卷是「交付」时的选择，不该被一次右键带出来。
                includeVolume: !silent
            )
            guard code == 0, verify else { return code }

            self.statusText = L("正在校验归档…")
            self.currentItem = nil
            // 分卷时真正落盘的是 `xxx.zip.001`，校验要指向第一卷，指 dest 会找不到文件。
            let verifyCode = await verifyArchive(Self.producedArchive(for: dest))
            // 255 是用户自己点了取消，不算校验失败，也不该报错。
            if verifyCode != 0, verifyCode != 255 {
                self.verifyFailure = Self.describeVerifyFailure(code: verifyCode)
            }
            return verifyCode == 0 ? 0 : code
        } completion: { code in
            defer { if silent { self.endSilentRun() } }
            let produced = Self.producedArchive(for: dest)

            // 先处理「压缩成功但校验不过」：产物不可信，此时绝不能删源文件，
            // 也不该像成功那样把包加载出来给用户看。
            if let failure = self.verifyFailure {
                self.verifyFailure = nil
                self.progress = 100
                self.currentItem = nil
                self.statusText = L("压缩已完成，但校验未通过")
                self.options.resetPassword()
                if silent {
                    self.reportSilentFailure(title: L("压缩已完成，但校验未通过"), message: failure)
                } else {
                    self.errorMessage = failure
                }
                return
            }

            if code == 0 {
                self.progress = 100  // 7zz 不保证打到 100%，成功后补齐。
                self.currentItem = nil
                var message = String(format: L("压缩完成 → %@"), produced.path)
                if let volumeCount = Self.volumeCount(for: produced), volumeCount > 1 {
                    message += String(format: L("（共 %d 卷）"), volumeCount)
                }
                if deleteSource {
                    let moved = self.moveToTrash(sources: sources, destination: produced)
                    if moved > 0 {
                        message = String(format: L("压缩完成 → %@（%d 个源文件已移到废纸篓）"), produced.path, moved)
                    }
                }
                self.statusText = message
                self.options.resetPassword()
                // 静默任务不给界面：不把新包读进窗口，产物就在用户右键的那个目录里，
                // 结果通过通知中心交付（跟 Keka 一致）。
                if silent {
                    var body = String(format: L("文件「%@」已创建"), produced.lastPathComponent)
                    if self.options.deleteSourceAfterCompress {
                        body += L("（源文件已保留，右键压缩不会自动删除）")
                    }
                    Notifier.shared.success(title: L("压缩完成"), body: body, reveal: produced)
                } else {
                    self.load(archive: produced)
                }
            } else {
                self.statusText = code == 255 ? L("已取消") : L("压缩失败")
                guard code != 255 else { return }
                let detail = Self.describe(exitCode: code)
                if silent {
                    self.reportSilentFailure(title: L("压缩失败"), message: detail)
                } else {
                    self.errorMessage = detail
                }
            }
        }
    }

    // MARK: - 分卷产物

    /// 分卷压缩落盘的是 `xxx.zip.001`，界面上要打开、要展示的是第一卷。
    /// 不分卷时原样返回 dest。
    private static func producedArchive(for dest: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return dest }
        let first = URL(fileURLWithPath: dest.path + ".001")
        if fm.fileExists(atPath: first.path) { return first }
        return dest
    }

    /// 卷数：第一卷存在时数同名的三位数字后缀文件；不是卷包就返回 nil。
    private static func volumeCount(for archive: URL) -> Int? {
        guard archive.path.hasSuffix(".001") else { return nil }
        let base = String(archive.path.dropLast(4))
        let fm = FileManager.default
        var count = 0
        while fm.fileExists(atPath: String(format: "%@.%03d", base, count + 1)) {
            count += 1
        }
        return count > 0 ? count : nil
    }

    /// 与 dest 同名的卷包（`xxx.zip.001` 起的三位序号文件）。
    /// 只认这一串，别的归档一律不碰。
    private static func volumeSet(for dest: URL) -> [URL] {
        let fm = FileManager.default
        let dir = dest.deletingLastPathComponent()
        let prefix = dest.lastPathComponent + "."
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { name -> URL? in
            guard name.hasPrefix(prefix) else { return nil }
            let suffix = name.dropFirst(prefix.count)
            guard suffix.count == 3, suffix.allSatisfy(\.isNumber) else { return nil }
            return dir.appendingPathComponent(name)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func removeVolumeSet(for dest: URL) {
        for url in volumeSet(for: dest) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 覆盖旧卷包会连带删掉用户已有的产物，动手前必须问一句。
    private func confirmReplacingVolumeSet(_ volumes: [URL]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("目标位置已有同名分卷包（共 %d 卷）"), volumes.count)
        alert.informativeText = String(format: L("「%@」将被替换，旧卷包会直接删除，无法从废纸篓恢复。"),
                                      volumes[0].lastPathComponent)
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("替换"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 压缩后删源文件属于不可轻易撤销的操作，即使设置里已经勾选也要再确认一次。
    private func confirmSourceRemovalIfNeeded(sources: [URL]) -> Bool {        guard options.deleteSourceAfterCompress else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("压缩完成后将把 %d 个源文件移到废纸篓"), sources.count)
        alert.informativeText = L("仅在压缩成功后执行，文件可从废纸篓恢复。")
        // 第一个按钮是默认按钮：把「取消」放在默认位，避免误触即删。
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("继续压缩"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 移到废纸篓而不是永久删除，用户随时可以从废纸篓找回。
    /// 归档若就在被压缩的目录里，跳过那一项，否则会连结果一起丢掉。
    @discardableResult
    private func moveToTrash(sources: [URL], destination: URL) -> Int {
        var moved = 0
        for url in sources {
            if destination.path.hasPrefix(url.path + "/") { continue }
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                moved += 1
            } catch {
                errorMessage = String(format: L("移到废纸篓失败：%@"), error.localizedDescription)
            }
        }
        return moved
    }

    // MARK: - Blocking 7zz operations (run off the main thread)

    /// - Parameter renameExisting: 静默解压用 `-aou`：目标目录里已有同名文件时
    ///   把新解出的文件改名（`a.txt` → `a_1.txt`），不覆盖任何现有文件。
    private func extractBlocking(
        archive: URL,
        to dest: URL,
        items: [String],
        renameExisting: Bool = false,
        silent: Bool = false
    ) async -> Int32 {
        // 已知有加密条目但还没拿到密码：先问，省掉一次必然失败的解压。
        if archiveEncrypted, archivePassword == nil {
            guard let entered = await askPassword(isRetry: false) else { return 255 }
            archivePassword = entered
        }

        // 路径预检：`/etc/x` 这种条目会被 7-Zip 静默搬到 `<目标>/etc/x`，
        // 用户只会看到凭空多出来的目录，所以先问一句再动手。
        if let blocked = await screenEntryPaths(archive: archive, items: items, silent: silent) {
            return blocked
        }

        // 拍个顶层快照，解压后用来算「这次多出了什么」。
        let before = ArchiveSafety.topLevelNames(of: dest)

        var result = await runExtract(
            archive: archive,
            to: dest,
            items: items,
            password: archivePassword,
            renameExisting: renameExisting
        )

        // 兜底：有些归档的加密条目在列目录时看不出（例如加密的 rar），
        // 跑到一半才报错，这时再问一次并重跑。
        if result.code != 0, Self.isPasswordError(result.error) {
            guard let entered = await askPassword(isRetry: archivePassword != nil) else { return 255 }
            archivePassword = entered
            result = await runExtract(
                archive: archive,
                to: dest,
                items: items,
                password: entered,
                renameExisting: renameExisting
            )
        }

        if result.code == 0 {
            await expandIntermediateTar(archive: archive, destination: dest, renameExisting: renameExisting)
        }

        // 复核：本次新增的顶层条目必须都落在目标目录内。
        // 只有归档夹带符号链接、且解压器没重写链接目标时才会命中，命中就是真的写出去了。
        let added = ArchiveSafety.topLevelNames(of: dest).subtracting(before)
        let escaped = ArchiveSafety.escaped(in: dest, added: added)
        if !escaped.isEmpty {
            reportEscape(escaped, in: dest, silent: silent)
            return Self.exitUnsafePath
        }

        return result.code
    }

    /// 解压前的路径预检。
    /// - Returns: 需要中止时返回退出码；`nil` 表示放行。
    private func screenEntryPaths(archive: URL, items: [String], silent: Bool) async -> Int32? {
        let listing = await runSync([
            "l", "-slt", "-ba", "-p\(archivePassword ?? "")", archive.path,
        ])
        // 列不出来（头部加密、损坏、分卷缺失）就不拦，交给 7-Zip 自己报错，免得误伤。
        guard listing.code == 0 else { return nil }

        let findings = ArchiveSafety.inspect(entries: ArchiveLister.parse(listing.output), items: items)
        guard !findings.isEmpty else { return nil }

        let detail = ArchiveSafety.summarize(findings)
        let fatal = findings.filter { $0.problem.isFatal }

        guard !fatal.isEmpty else {
            // 只有 `../`：7-Zip 会剥掉层级落平在目标里，安全，只是名字会变。
            // 不打断，解压成功后把这件事写进提示里。
            pendingSafetyNote = String(
                format: L("有 %d 个条目的路径向上跳级（../），已按落平后的名字解出"),
                findings.count
            )
            return nil
        }

        let title = String(
            format: L("「%@」中有 %d 个条目路径异常"),
            archive.lastPathComponent, findings.count
        )
        let consequence = L("这类条目会被解压器改写后写到目标文件夹里，目录结构可能和压缩包内看到的不一致。")

        if silent {
            // 通知由任务收尾统一发，这里只留文案，避免一次失败弹两条通知。
            pendingSafetyFailure = detail + "\n" + consequence
            return Self.exitUnsafePath
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail + "\n\n" + consequence
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("仍然解压"))
        return alert.runModal() == .alertSecondButtonReturn ? nil : Self.exitUnsafePath
    }

    /// 解压后发现内容被写到目标目录外：这个必须让人知道，不能只写日志。
    private func reportEscape(_ paths: [String], in dest: URL, silent: Bool) {
        let sample = paths.prefix(3).map { "· \($0)" }.joined(separator: "\n")
        let message = String(
            format: L("有 %d 项内容被写到了「%@」之外：\n%@\n\n源归档可能带有指向目录外的符号链接。建议检查这些位置，确认是否还需要保留。"),
            paths.count, dest.lastPathComponent, sample
        )
        if silent {
            pendingSafetyFailure = message
        } else {
            errorMessage = message
        }
    }

    /// 解压时排除的辅助文件。只影响解压产物，不改变压缩包本身。
    private static func extractionExcludes() -> [String] {
        let settings = SettingsStore.shared
        var args: [String] = []
        if settings.filterSystemAux {
            args += ["-xr!__MACOSX", "-xr!.DS_Store", "-xr!._*", "-xr!Thumbs.db", "-xr!desktop.ini"]
        }
        if settings.filterDMGAux {
            args += ["-xr!.background", "-xr!.fseventsd", "-xr!.Trashes", "-xr!.VolumeIcon.icns"]
        }
        return args
    }

    private func runExtract(
        archive: URL,
        to dest: URL,
        items: [String],
        password: String?,
        renameExisting: Bool = false
    ) async -> (code: Int32, error: String) {
        let runner = self.runner
        var args = ["x", archive.path, "-o\(dest.path)", "-y", "-bsp1", "-bb1", "-p\(password ?? "")"]
        if renameExisting { args.append("-aou") }
        args.append(contentsOf: Self.extractionExcludes())
        args.append(contentsOf: items)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var code: Int32 = -1
                var errorText = ""
                do {
                    let process = try runner.start(
                        arguments: args,
                        onProgress: { [weak self] event in
                            DispatchQueue.main.async {
                                guard let self else { return }
                                if self.progress < event.percent { self.progress = event.percent }
                                if let item = SevenZipRunner.parseCurrentItem(event.raw) {
                                    self.currentItem = item
                                }
                            }
                        },
                        onError: { line in
                            errorText += line + "\n"
                        }
                    )
                    DispatchQueue.main.async { self?.activeProcess = process }
                    process.waitUntilExit()
                    code = process.terminationStatus
                } catch {
                    DispatchQueue.main.async { self?.errorMessage = "\(error)" }
                }
                continuation.resume(returning: (code, errorText))
            }
        }
    }

    /// `.tar.gz` / `.tar.bz2` / `.tar.xz` 是「压缩器套 tar」，7zz 只会解开外层，
    /// 留下一个 `.tar`。这里把中间那一层也拆开，用户直接拿到内容。
    ///
    /// 静默解压的目标是用户自己的文件夹，里面本来就有东西，所以不能再用
    /// 「目录里只有一个文件」判断中间产物，改成按归档名去找那个 `.tar`。
    private func expandIntermediateTar(archive: URL, destination: URL, renameExisting: Bool) async {
        let ext = archive.pathExtension.lowercased()
        guard ["gz", "bz2", "xz", "z", "tgz", "tbz", "tbz2", "txz"].contains(ext) else { return }

        let fm = FileManager.default
        // 常规情形：`a.tar.gz` 解出来就叫 `a.tar`，就落在目标目录里。
        let expected = destination.appendingPathComponent(Self.archiveStem(archive) + ".tar")
        var tar: URL?
        if fm.fileExists(atPath: expected.path) {
            tar = expected
        } else {
            // 兜底：目标目录是刚建出来的空文件夹时（界面链路），里面唯一的 `.tar` 就是它。
            let listing = (try? fm.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            if listing.count == 1, let only = listing.first, only.pathExtension.lowercased() == "tar" {
                tar = only
            }
        }
        guard let tar else { return }

        var args = ["x", tar.path, "-o\(destination.path)", "-y", "-bso0", "-bsp0", "-p"]
        if renameExisting { args.append("-aou") }

        let result = await runSync(args)
        if result.code == 0 {
            // 中间产物是刚才这一步自己解出来的，展开后清掉，不留在用户目录里。
            try? fm.removeItem(at: tar)
        }
    }

    private func compressBlocking(
        sources: [URL],
        to dest: URL,
        progressCap: Int,
        includeVolume: Bool
    ) async -> Int32 {
        // gzip / bzip2 / xz 一次只能压一个文件流，目录或多项必须先打 tar。
        if options.format.isSingleStream, sources.count > 1 || sources.contains(where: Self.isDirectory) {
            return await compressViaTar(sources: sources, to: dest, progressCap: progressCap)
        }
        return await runCompress(
            sources: sources,
            to: dest,
            progressRange: 0...progressCap,
            includeVolume: includeVolume
        )
    }

    /// 压缩后自检。`7zz t` 只读归档、逐项比对 CRC，不落盘。
    ///
    /// 必须带密码：加密包里这条命令拿不到密码就会报
    /// `Data Error in encrypted file. Wrong password?`，看起来跟文件损坏一样，
    /// 极易误判成压缩出了问题。
    private func verifyArchive(_ archive: URL) async -> Int32 {
        let args = ["t", archive.path, "-p\(options.password)", "-bsp1", "-bb1"]
        return await runWithProgress(args, progressRange: 90...100)
    }

    private func runCompress(
        sources: [URL],
        to dest: URL,
        progressRange: ClosedRange<Int>,
        includeVolume: Bool
    ) async -> Int32 {
        var args = ["a", dest.path]
        args.append(contentsOf: options.extraArguments(includeVolume: includeVolume))
        args.append(contentsOf: ["-bsp1", "-bb1"])
        args.append(contentsOf: sources.map(\.path))
        return await runWithProgress(args, progressRange: progressRange)
    }

    /// 两步走：先打 tar，再用 gzip/bzip2/xz 压。
    /// 产物是标准的 `.tar.gz` / `.tar.bz2` / `.tar.xz`，解压时由
    /// `expandIntermediateTar` 还原成内容。
    private func compressViaTar(sources: [URL], to dest: URL, progressCap: Int) async -> Int32 {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Threxo-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
            return -1
        }
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tarURL = tmpDir.appendingPathComponent("payload.tar")
        var tarArgs = ["a", tarURL.path, "-ttar"]
        tarArgs.append(contentsOf: options.excludeArguments())
        tarArgs.append(contentsOf: ["-bso0", "-bsp0"])
        tarArgs.append(contentsOf: sources.map(\.path))

        let mid = progressCap / 2
        let tarCode = await runWithProgress(tarArgs, progressRange: 0...mid)
        guard tarCode == 0 else { return tarCode }

        var args = ["a", dest.path, options.format.typeFlag]
        if options.format.supportsLevel {
            args.append("-mx=\(options.level.mx)")
        }
        args.append(contentsOf: ["-bsp1", "-bb1", tarURL.path])
        return await runWithProgress(args, progressRange: mid...progressCap)
    }

    /// 跑一次 7zz 并把百分比映射到 `progressRange` 区间（两步流程用）。
    /// - Parameter workingDirectory: 往归档里追加文件时设成镜像目录，
    ///   这样参数里的相对路径就是归档内的条目路径。
    private func runWithProgress(
        _ args: [String],
        workingDirectory: URL? = nil,
        progressRange: ClosedRange<Int>
    ) async -> Int32 {
        let runner = self.runner
        let span = Double(progressRange.upperBound - progressRange.lowerBound)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var code: Int32 = -1
                do {
                    let process = try runner.start(
                        arguments: args,
                        workingDirectory: workingDirectory,
                        onProgress: { [weak self] event in
                            let mapped = progressRange.lowerBound + Int(Double(event.percent) / 100.0 * span)
                            DispatchQueue.main.async {
                                guard let self else { return }
                                if self.progress < mapped { self.progress = mapped }
                                if let item = SevenZipRunner.parseCurrentItem(event.raw) {
                                    self.currentItem = item
                                }
                            }
                        },
                        onError: { _ in }
                    )
                    DispatchQueue.main.async { self?.activeProcess = process }
                    process.waitUntilExit()
                    code = process.terminationStatus
                } catch {
                    DispatchQueue.main.async { self?.errorMessage = "\(error)" }
                }
                continuation.resume(returning: code)
            }
        }
    }

    /// 同步跑一次 7zz，收集 stdout / stderr。用于列目录、拆中间 tar 这类短命令。
    private func runSync(_ args: [String]) async -> (code: Int32, output: String, error: String) {
        let runner = self.runner
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = (try? runner.runCollecting(arguments: args))
                    ?? (code: -1, output: "", error: "")
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - 静默任务（访达右键）

    /// 进入静默模式：没有主窗口可依附，进度只在菜单栏显示。
    /// - Returns: 是否真的无窗口运行；主窗口可见时返回 false，任务照旧在窗口里跑。
    @discardableResult
    private func beginSilentRun() -> Bool {
        let headless = AppDelegate.shared?.beginHeadlessJob() ?? false
        appDbg("beginSilentRun headless=\(headless)")
        silentRun = headless
        return headless
    }

    private func endSilentRun() {
        guard silentRun else { return }
        silentRun = false
        AppDelegate.shared?.endHeadlessJob()
    }

    /// 静默失败一律走通知，不弹任何窗口——右键链路本来就不该打断用户手上的事。
    /// - Parameter lines: 保留的行数。7zz 的原始报错取首段就够，安全检查的
    ///   结论需要首行加样例路径，多留两行。
    private func reportSilentFailure(title: String, message: String, lines: Int = 1) {
        let kept = message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(max(1, lines))
            .joined(separator: "\n")
        let brief = kept.isEmpty ? message : kept
        Notifier.shared.failure(
            title: title,
            body: brief.count > 220 ? String(brief.prefix(220)) + "…" : brief
        )
    }

    // MARK: - Task plumbing

    /// Runs `work` off-main with the busy spinner, then calls `completion` on main.
    private func runTask(
        status: String,
        work: @escaping @MainActor () async -> Int32,
        completion: @escaping @MainActor (Int32) -> Void
    ) {
        isBusy = true
        progress = 0
        errorMessage = nil
        currentItem = nil
        statusText = status
        Task.detached(priority: .userInitiated) {
            let code = await work()
            await MainActor.run {
                self.activeProcess = nil
                self.isBusy = false
                completion(code)
            }
        }
    }

    func cancel() {
        activeProcess?.terminate()
    }

    // MARK: - URL scheme (threxo://extract|compress?path=…)

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "threxo" else { return }
        let paths = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        appDbg("handleIncomingURL host=\(url.host ?? "nil") paths=\(urls.count)")
        switch url.host {
        case "extract":
            extractAutomatically(urls)
        case "compress":
            compressAutomatically(urls)
        case "add":
            #if DEBUG
            debugAdd(url)
            #endif
        #if DEBUG
        case "about":
            // 仅调试：脚本里验一下关于/许可页能正常渲染，Release 不存在这个入口。
            AboutWindowController.shared.show()
        case "settings":
            // 仅调试：`threxo://settings?page=extract` 直接落到某一页，方便逐页核对布局。
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value
            SettingsWindowController.shared.show(page: SettingsPage(rawValue: page ?? "") ?? .general)
        #endif
        default:
            break
        }
    }

    #if DEBUG
    /// 仅调试构建：`threxo://add?archive=…&dir=子目录&path=…&path=…`
    ///
    /// 拖拽本身没法脚本化（要真按鼠标），所以留这个入口跑通
    /// 「先读归档 → 再追加 → 回读」这条链路，Release 里不存在。
    private func debugAdd(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let archivePath = items.first(where: { $0.name == "archive" })?.value else { return }
        let folder = items.first(where: { $0.name == "dir" })?.value ?? ""
        let files = items.filter { $0.name == "path" }.compactMap(\.value)
            .map { URL(fileURLWithPath: $0) }
        let archive = URL(fileURLWithPath: archivePath)

        Task { @MainActor in
            let result = await self.list(archive, password: nil)
            guard result.code == 0 else {
                appDbg("debugAdd 读取归档失败 code=\(result.code) err=\(result.error)")
                return
            }
            let parsed = ArchiveLister.parse(result.output)
            self.archiveURL = archive
            self.entries = parsed
            self.treeNodes = ArchiveTree.build(parsed)
            appDbg("debugAdd entries=\(parsed.count) files=\(files.count) dir=\(folder)")
            self.addDroppedFiles(files, toFolder: folder)
        }
    }
    #endif

    // MARK: - Helpers

    /// 密码框：挂起等待用户输入，取消返回 nil。
    ///
    /// 静默任务没有主窗口，`passwordPrompt` 对应的 sheet 永远弹不出来——那种情况下
    /// 改用独立的 `NSAlert` 密码框，否则整个任务会卡在等待上，用户只看到进度条不动。
    @MainActor
    private func askPassword(isRetry: Bool) async -> String? {
        if silentRun {
            return Self.promptPasswordWithAlert(isRetry: isRetry)
        }
        return await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            passwordPrompt = PasswordPrompt(
                title: isRetry ? L("密码不正确") : L("需要密码"),
                message: isRetry
                    ? L("这个归档的密码不对，请重新输入。")
                    : L("这个归档已加密，需要密码才能解压。")
            )
        }
    }

    /// 无窗口场景的密码输入：阻塞式弹窗，输完继续。
    private static func promptPasswordWithAlert(isRetry: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isRetry ? L("密码不正确") : L("需要密码")
        alert.informativeText = isRetry
            ? L("这个归档的密码不对，请重新输入。")
            : L("这个归档已加密，需要密码才能解压。")
        alert.addButton(withTitle: L("解压"))
        alert.addButton(withTitle: L("取消"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("密码")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue
        return text.isEmpty ? nil : text
    }

    func submitPassword(_ text: String) {
        passwordPrompt = nil
        passwordContinuation?.resume(returning: text.isEmpty ? nil : text)
        passwordContinuation = nil
    }

    func cancelPassword() {
        passwordPrompt = nil
        passwordContinuation?.resume(returning: nil)
        passwordContinuation = nil
    }

    /// 7zz 的两种密码报错：条目级 `Wrong password : path`，
    /// 头部加密 `Cannot open encrypted archive. Wrong password?`。
    static func isPasswordError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("wrong password") || lowered.contains("cannot open encrypted archive")
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// 默认归档名：单个项目用它自己的名字，多个项目用「归档」。
    static func defaultArchiveBase(for urls: [URL]) -> String {
        guard urls.count == 1, let first = urls.first else { return L("归档") }
        // 对着一个已有归档再压缩，按归档规则取主干（a.tar.gz → a），
        // 否则会叠成「a.tar.zip」这种需要二次解压的名字。
        let stem = isArchiveURL(first)
            ? archiveStem(first)
            : first.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? L("归档") : stem
    }

    /// 解压目标：归档同级的同名文件夹，已存在则依次尝试「名字 2」「名字 3」…，
    /// 绝不覆盖已有目录（避免解压把上一个结果覆盖掉）。
    private func uniqueExtractDestination(for archive: URL) -> URL {
        let dir = archive.deletingLastPathComponent()
        let stem = Self.archiveStem(archive)
        var candidate = dir.appendingPathComponent(stem)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// 归档内路径统一成「无 `./` 前缀、无结尾斜杠」的形式，便于比较与拼层级。
    static func normalizeEntryPath(_ raw: String) -> String {
        var path = raw
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == "." ? "" : path
    }

    /// `a.tar.gz` → `a`，`b.zip` → `b`。
    static func archiveStem(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name.isEmpty ? L("解压结果") : name
    }

    /// 把选中项展开成具体文件路径：选了文件夹就带上里面的所有条目，
    /// 这样即使 7zz 对目录参数的处理有差异也能保证结果正确。
    private func expandSelection(_ selected: Set<String>) -> [String] {
        let directories = entries
            .filter { $0.isDirectory && selected.contains($0.path) }
            .map(\.path)

        guard !directories.isEmpty else {
            return selected.sorted()
        }

        var result: [String] = []
        for entry in entries where !entry.isDirectory {
            if selected.contains(entry.path)
                || directories.contains(where: { entry.path.hasPrefix($0 + "/") }) {
                result.append(entry.path)
            }
        }
        return result.isEmpty ? selected.sorted() : result.sorted()
    }

    static func isArchiveURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // 分卷包的第一卷（xxx.zip.001）：去掉 .001 之后仍然是归档，认它。
        if ext == "001" {
            return archiveExtensions.contains(url.deletingPathExtension().pathExtension.lowercased())
        }
        if archiveExtensions.contains(ext) { return true }
        return url.deletingPathExtension().pathExtension.lowercased() == "tar"
    }

    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2",
        "xz", "txz", "zst", "lz", "lzma", "cab", "iso", "wim", "jar", "war",
    ]

    /// 把 7-Zip 的退出码翻译成人话，替代裸露的 "退出码 2"。
    static func describe(exitCode: Int32) -> String {
        switch exitCode {
        case 0: return L("完成")
        case 1: return L("完成，但有部分文件被跳过（可能被占用、无权限或路径过长）")
        case 2: return L("归档损坏、密码错误，或目标磁盘写入失败")
        case 7: return L("命令参数错误")
        case 8: return L("内存不足，请关闭其他应用后重试")
        case 254: return L("归档内的条目路径异常，已停止解压")
        case 255: return L("已取消")
        default: return String(format: L("未知错误（7-Zip 退出码 %d）"), exitCode)
        }
    }

    /// 自检失败的提示。这里要给的是「下一步做什么」，不是退出码。
    /// 退出码 2 覆盖了读不全、CRC 不符、磁盘写入失败三种情况，统一按
    /// 「产物不可信」处理：保住源文件，重压一次。
    static func describeVerifyFailure(code: Int32) -> String {
        if code == 2 {
            return L("归档校验未通过：文件可能不完整或已损坏。源文件已保留，请重新压缩一次；若反复失败，检查目标磁盘的剩余空间与健康状态。")
        }
        return String(format: L("归档校验未通过：%@"), describe(exitCode: code))
    }

    // MARK: - Types

    static let archiveTypes: [UTType] = {
        var types: [UTType] = [.zip, .gzip]
        for ext in ["7z", "rar", "tar", "bz2", "xz", "tgz", "cab", "iso"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()
}

#if DEBUG
extension AppModel {
    /// 仅调试：同步等归档读完，供离屏快照使用。
    func debugLoadAndWait(_ archive: URL) {
        load(archive: archive)
        let deadline = Date().addingTimeInterval(8)
        while isBusy, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        appDbg("debugLoadAndWait entries=\(allEntries.count) busy=\(isBusy)")
    }
}
#endif
