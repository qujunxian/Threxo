import Foundation
import AppKit
import Combine
import Darwin
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
///     压缩产物落在当前目录，不建主窗口、不弹位置选择，进度由统一浮层显示
///     （菜单栏另有一份兜底进度与取消入口）。
/// 解压完成后问一次「原包要不要移入废纸篓」。
/// 只有窗口链路会用到；访达右键的静默解压不弹任何东西。
struct ExtractCompletionPrompt: Identifiable {
    let id = UUID()
    let archive: URL
}

/// 一层嵌套压缩包：`url` 是从父包里解到临时目录的内层包。
/// 退出这一层时把 `tempDirectory` 一起删掉，不把 /tmp 越堆越满。
struct NestedArchive: Identifiable {
    let id = UUID()
    let url: URL
    let parentURL: URL
    let entryPath: String
    let tempDirectory: URL
}

final class AppModel: ObservableObject {
    /// 单例：AppDelegate 的 openFiles 回调需要一个稳定入口。
    static let shared = AppModel()

    @Published var archiveURL: URL?
    /// 嵌套压缩包的层级栈。空 = 当前看的是磁盘上那个原始包。
    @Published private(set) var nestedChain: [NestedArchive] = []
    /// 从内层退回外层时，把刚才那个内嵌包重新选中。
    private var pendingSelection: String?
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

    @Published var isBusy = false {
        didSet {
            guard oldValue != isBusy else { return }
            if isBusy {
                busyStartedAt = Date()
                lastTaskActivity = Date()
            } else {
                busyStartedAt = nil
                activeProcess = nil
            }
        }
    }
    /// 当前压缩 / 解压任务的进度弹窗状态。非 nil 时由 `TaskProgressPanel` 显示浮层，
    /// 主窗口底栏的旧进度条让位（见 ContentView.footer）。
    /// 页面链路与访达右键 / 双击静默链路共用这一份状态，进度展示只有一套。
    @Published var taskProgress: TaskProgressState? {
        didSet {
            if let state = taskProgress {
                TaskProgressPanel.shared.show(state)
            } else {
                TaskProgressPanel.shared.hide()
            }
        }
    }

    // 任务已收尾（finished）后不再同步：压缩成功会顺手 load 新归档，
    // 那个流程又会 isBusy=true / progress=0，别把已经补满的 100% 打回去。
    @Published var progress: Int = 0 {
        didSet {
            guard taskProgress?.finished == false else { return }
            taskProgress?.percent = progress
            #if DEBUG
            // 每跨过一个十位数记一笔，用来核对浮层确实跟着 7zz 的进度在走。
            if progress / 10 != oldValue / 10 {
                appDbg("taskProgress \(progress)% item=\(currentItem ?? "-")")
            }
            #endif
        }
    }
    @Published var statusText = L("就绪") {
        didSet { if taskProgress?.finished == false { taskProgress?.phase = statusText } }
    }
    @Published var errorMessage: String?
    /// 当前正在处理的文件（来自 7zz -bb1 的进度行）。
    @Published var currentItem: String? {
        didSet { if taskProgress?.finished == false { taskProgress?.currentItem = currentItem } }
    }

    /// 访达右键扩展是否已在「系统设置 → 登录项与扩展」里启用。
    /// 由 pkd 提供，状态可能滞后数秒，界面上提供手动刷新。
    @Published var finderExtensionEnabled = false

    /// 常用格式里还没交给千梭的数量。双击压缩包没反应时，欢迎页据此提示去关联。
    @Published private(set) var unassociatedCommonCount = 0

    /// 压缩设置（格式 / 级别 / 密码 / 排除 / 删源），与界面共享同一实例。
    let options = CompressionOptions.shared

    /// 解压加密归档时的密码框；非 nil 表示正在等用户输入。
    @Published var passwordPrompt: PasswordPrompt?
    @Published var extractCompletionPrompt: ExtractCompletionPrompt?

    /// 访达右键「压缩为…」传进来的源。非 nil 时界面挂出压缩向导，
    /// 向导确认后直接进保存面板，不再让用户选一遍文件。

    /// 拖入文件（或追加）成功后要展开并选中的条目，供列表自动定位。
    @Published var revealRequest: RevealRequest?

    struct RevealRequest: Equatable {
        let id = UUID()
        /// 需要展开的目录（含各级父目录），按由浅到深排列。
        let folders: [String]
        /// 要选中的条目路径。
        let entries: [String]
    }

    /// 攒批用的缓冲区：访达逐个投递时，400ms 内的请求算同一批。
    private var pendingSilentCompress: [URL] = []
    private var silentCompressToken = 0
    /// 合并窗口。太短则冷启动时后续事件还没到就提前压了，太长用户要等。
    static let silentCompressWindow: TimeInterval = 0.4

    /// 本次归档已确认可用的密码，只存在内存里，切换归档即清空。
    private var archivePassword: String?
    /// 归档是否含加密条目（来自 `l -slt` 的 `Encrypted = +`）。详情面板要用，所以要能观察。
    @Published private(set) var archiveEncrypted = false
    private var passwordContinuation: CheckedContinuation<String?, Never>?

    private var activeProcess: Process?
    private let runner: SevenZipRunner

    /// isBusy 从什么时刻开始，仅用于日志与卡死判定。
    private var busyStartedAt: Date?
    /// 最近一次「确实有进展」的时刻：进程起来、7zz 报进度、列目录开始 / 结束。
    /// 判定卡死必须同时满足「没有子进程在跑」和「这里很久没动」，只看时间会误杀大文件压缩。
    private var lastTaskActivity = Date()

    /// 无进展多久算卡死。7zz 在极限压缩时可能长时间不吐进度，所以阈值放宽到 20 秒；
    /// 真正的判定条件是「同时没有子进程」，那种情况下根本不可能再前进。
    private static let stallTimeout: TimeInterval = 20

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

    /// 往提示里追加一句（多条提示用「；」隔开）。
    private func appendSafetyNote(_ note: String) {
        if let existing = pendingSafetyNote, !existing.isEmpty {
            pendingSafetyNote = existing + "；" + note
        } else {
            pendingSafetyNote = note
        }
    }

    /// 安全检查拦下解压时的详细说明。写成属性是因为静默链路的通知
    /// 由任务收尾统一发一次，中途再发一条就成了重复打扰。
    private var pendingSafetyFailure: String?

    /// 自定义退出码：路径安全检查未通过。
    static let exitUnsafePath: Int32 = 254
    /// 自定义退出码：目标卷空间不足（静默链路）。
    static let exitInsufficientSpace: Int32 = 253

    /// 本次解压实际落到的目录。用户在空间预检里点了「换位置」之后，
    /// 目标就不再是调用方传进来的那个，收尾提示与「在访达中显示」都得跟着改。
    private var lastExtractDestination: URL?

    /// 本次解压新增的顶层条目。完成后在访达里选中「产物」而不是「目标目录」：
    /// `activateFileViewerSelecting` 传目录时打开的是它的父目录并选中该目录，
    /// 双击静默解压平铺到当前目录时会因此弹到上一层。
    private var lastExtractedItems: [URL] = []

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

    /// 重新向系统查询扩展启用状态，顺带核对常用格式的默认打开程序。
    /// 格式关联要问 LaunchServices 二十多次，放到后台算完再回主线程，别卡住窗口出现动画。
    func refreshFinderExtensionState() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        if enabled != finderExtensionEnabled {
            finderExtensionEnabled = enabled
        }
        DispatchQueue.global(qos: .utility).async {
            let bindings = SettingsStore.shared.currentFormatBindings()
            let count = bindings.filter { !$0.cautious && $0.uti != nil && !$0.isDefault }.count
            DispatchQueue.main.async { [weak self] in
                self?.unassociatedCommonCount = count
            }
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
        guard canStartTask() else { return }
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
        // 用户主动换了一个包：整条嵌套链和它们的临时文件都作废。
        closeAllNestedArchives()
        loadArchive(url)
    }

    /// 真正把包读进界面。嵌套打开与退回外层都走这里，不动嵌套链。
    private func loadArchive(_ url: URL, selecting path: String? = nil) {
        pendingSelection = path
        isBusy = true
        noteActivity()
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
            // 开着「自动尝试」时先拿密码本里的密码列一次目录，能过就不打扰用户。
            var password: String? = SettingsStore.shared.vaultAutoTry
                ? PasswordVault.shared.password(for: url.lastPathComponent)
                : nil
            var attempt = 0
            var cancelled = false
            var result = await list(url, password: password)
            if result.code != 0, password != nil {
                // 自动试的密码不对，按无密码重列一次，别把错的当成有效密码带下去。
                password = nil
                result = await list(url, password: nil)
            }

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

    // MARK: - 嵌套压缩包

    var isNestedArchive: Bool { !nestedChain.isEmpty }

    /// 解压目标必须锚定在**磁盘上那个原始包**旁边。
    /// 嵌套时 `archiveURL` 指向 `/tmp/ThrexoDrop-…/<内层包>`，是临时副本；
    /// 拿它推导目录会把结果解进临时目录，退回外层就被清掉、用户在访达里根本找不到。
    /// 多层嵌套时 `nestedChain[0].parentURL` 始终是最外层那个真实文件。
    var extractionAnchorURL: URL? {
        if let root = nestedChain.first?.parentURL { return root }
        return archiveURL
    }

    /// 祖先链：outer.zip › mid.zip，标题与详情栏都用它。
    var nestedTrail: String {
        archiveBreadcrumb.dropLast().joined(separator: " › ")
    }

    /// 面包屑：原始包 › 第一层 › 第二层。
    var archiveBreadcrumb: [String] {
        var names: [String] = []
        if let root = nestedChain.first?.parentURL.lastPathComponent {
            names.append(root)
        }
        names.append(contentsOf: nestedChain.map { $0.url.lastPathComponent })
        return names
    }

    /// 这个条目本身是不是压缩包（是的话才能嵌进去看）。
    func canOpenNested(path: String, isDirectory: Bool) -> Bool {
        guard !isDirectory else { return false }
        return Self.isArchiveURL(URL(fileURLWithPath: path))
    }

    /// 双击一行：目前只有内嵌压缩包有动作。
    func openEntry(path: String, isDirectory: Bool) {
        guard canOpenNested(path: path, isDirectory: isDirectory) else { return }
        openNestedArchive(path: path)
    }

    /// 把内层包解到临时目录，然后当作当前归档打开。
    func openNestedArchive(path: String) {
        guard let archive = archiveURL, canStartTask() else { return }
        let normalized = Self.normalizeEntryPath(path)
        guard let entry = allEntries.first(where: { Self.normalizeEntryPath($0.path) == normalized }),
              !entry.isDirectory,
              Self.isArchiveURL(URL(fileURLWithPath: normalized)) else { return }

        let password = archivePassword ?? (SettingsStore.shared.vaultAutoTry
            ? PasswordVault.shared.password(for: archive.lastPathComponent)
            : nil)
        let executable = runner.executableURL

        isBusy = true
        progress = 0
        errorMessage = nil
        statusText = L("正在打开内嵌压缩包…")
        noteActivity()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let temp = try ArchiveExport.materialize(
                    archive: archive,
                    items: [normalized],
                    pathInArchive: normalized,
                    password: password,
                    executable: executable
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.nestedChain.append(NestedArchive(
                        url: temp,
                        parentURL: archive,
                        entryPath: normalized,
                        tempDirectory: temp.deletingLastPathComponent()
                    ))
                    self.loadArchive(temp)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    self.statusText = L("打开内嵌压缩包失败")
                    self.errorMessage = L("这个内嵌压缩包打不开，可能加密了或者文件不完整")
                }
            }
        }
    }

    /// 退回上一层，顺手删掉这一层的临时文件。
    func closeNestedArchive() {
        guard !nestedChain.isEmpty else { return }
        popNestedArchives(keeping: nestedChain.count - 1)
    }

    /// 面包屑导航：保留 `keep` 层。
    /// - keep = 0：回到磁盘上的原始包
    /// - keep = n：回到第 n 层内嵌包（n 从 1 开始数）
    func popNestedArchives(keeping keep: Int) {
        guard keep >= 0, keep < nestedChain.count else { return }
        let target = keep == 0 ? nestedChain[0].parentURL : nestedChain[keep - 1].url
        // 回到目标层后，把当初从这里钻进去的那个条目重新选中。
        let selecting = nestedChain[keep].entryPath
        while nestedChain.count > keep {
            let last = nestedChain.removeLast()
            try? FileManager.default.removeItem(at: last.tempDirectory)
        }
        loadArchive(target, selecting: selecting)
    }

    /// 打开别的包、关闭窗口时，把整条链和临时文件清干净。
    func closeAllNestedArchives() {
        guard !nestedChain.isEmpty else { return }
        for level in nestedChain {
            try? FileManager.default.removeItem(at: level.tempDirectory)
        }
        nestedChain = []
        pendingSelection = nil
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
        if let password, SettingsStore.shared.vaultAutoSave {
            PasswordVault.shared.upsert(name: url.lastPathComponent, password: password, note: "")
        }
        allEntries = ArchiveLister.parse(result.output)
        baseDirty = true
        rebuildVisible()
        // 从内层退回来时，把刚才那个内嵌包选中，用户一眼看到自己从哪退的。
        if let pending = pendingSelection {
            pendingSelection = nil
            if let match = entries.first(where: { Self.normalizeEntryPath($0.path) == pending }) {
                selection = [match.path]
            }
        }
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

    /// 双击归档 / 拖到窗口 / 拖到 Dock 图标 / 「打开方式」都会走到这里。
    func receiveOpenFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let archives = urls.filter { Self.isArchiveURL($0) }
        if let first = archives.first {
            load(archive: first)
        } else {
            // 非归档（文件夹、普通文件）：不再直接开压，先进创建页把源填进清单，
            // 用户可以继续追加、删减、改格式，确认后才保存——和「创建压缩包」一个流程。
            // 访达右键的「用千梭压缩」仍走 compressAutomatically，保留一步到位的快速链路。
            MainWindowController.shared.show()
            ComposeArchiveState.shared.activate(sources: urls)
        }
    }

    // MARK: - 清理 macOS 辅助文件（访达右键）

    /// 访达右键「用千梭清理 macOS 辅助文件」：递归清掉文件夹里的
    /// `__MACOSX`、`.DS_Store`、`._*`、`.fseventsd`、`.Trashes`、
    /// `.Spotlight-V100`、`.TemporaryItems`、`.DocumentRevisions-V100`。
    /// 只删这些明确目标，不碰其他内容；不跟随符号链接，也不进入 .app 等包内部。
    func cleanMacAuxiliaryFiles(in folders: [URL]) {
        guard !folders.isEmpty, !isBusy else { NSSound.beep(); return }
        let silent = beginSilentRun()
        statusText = L("正在清理 macOS 辅助文件…")
        Task.detached(priority: .userInitiated) {
            let summary = Self.removeMacAuxiliaryFiles(in: folders)
            await MainActor.run {
                self.statusText = summary.message
                guard silent else { return }
                if summary.failed > 0 {
                    Notifier.shared.failure(
                        title: L("清理完成，但有文件没删掉"),
                        body: summary.message
                    )
                } else {
                    Notifier.shared.success(
                        title: summary.removed > 0
                            ? L("macOS 辅助文件已清理")
                            : L("没有找到 macOS 辅助文件"),
                        body: summary.message,
                        reveal: nil
                    )
                }
                self.endSilentRun()
            }
        }
    }

    struct CleanSummary {
        var removed = 0
        var failed = 0
        var bytes: Int64 = 0

        var message: String {
            if removed == 0 && failed == 0 {
                return L("这个文件夹里没有 macOS 辅助文件")
            }
            if failed == 0 {
                return String(format: L("已清理 %d 个辅助文件，释放 %@"),
                              removed, TaskProgressState.byteString(bytes))
            }
            return String(format: L("已清理 %d 个，%d 个没删掉"), removed, failed)
        }
    }

    /// 只在后台线程调用。返回删除数量、失败数量与释放的字节数。
    static func removeMacAuxiliaryFiles(in folders: [URL]) -> CleanSummary {
        let fm = FileManager.default
        var summary = CleanSummary()
        // 不碰系统目录与磁盘根：右键 / 或 /System 时递归清 .DS_Store 既慢又危险。
        let protected: Set<String> = ["/", "/System", "/Library", "/Applications", "/Volumes"]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                         .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]

        for folder in folders {
            let root = folder.standardizedFileURL
            guard !protected.contains(root.path), isDirectory(root) else {
                summary.failed += 1
                continue
            }
            var stack: [URL] = [root]
            while let dir = stack.popLast() {
                guard let names = directoryEntryNames(at: dir.path) else {
                    summary.failed += 1
                    continue
                }
                for name in names {
                    let url = dir.appendingPathComponent(name)
                    let values = try? url.resourceValues(forKeys: keys)
                    // 符号链接一律不碰：删链接没意义，还可能把目标带偏。
                    if values?.isSymbolicLink == true { continue }
                    if isMacAuxiliaryName(name) {
                        if values?.isDirectory == true {
                            summary.bytes += totalSizeIncludingHidden(url)
                        } else {
                            summary.bytes += Int64(values?.fileSize ?? 0)
                        }
                        do {
                            try fm.removeItem(at: url)
                            summary.removed += 1
                        } catch {
                            summary.failed += 1
                        }
                        continue
                    }
                    // 普通目录才继续下钻；.app 等包内部不动。
                    if values?.isDirectory == true, values?.isPackage != true {
                        stack.append(url)
                    }
                }
            }
        }
        appDbg("cleanMacUtils removed=\(summary.removed) failed=\(summary.failed) bytes=\(summary.bytes)")
        return summary
    }

    /// 目录项的真实名字。`FileManager.contentsOfDirectory` 在 APFS 上会把
    /// `._foo` 当成 `foo` 的资源分支隐藏掉，只有 POSIX `readdir` 能拿到，
    /// 而这些文件正是拷到 Windows / Linux 后最碍眼的噪音。
    private static func directoryEntryNames(at path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let offset = MemoryLayout<dirent>.offset(of: \.d_name) ?? 0
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = String(cString: UnsafeRawPointer(entry)
                .advanced(by: offset)
                .assumingMemoryBound(to: CChar.self))
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    static func isMacAuxiliaryName(_ name: String) -> Bool {
        if name == ".DS_Store" || name == "__MACOSX" { return true }
        if name.hasPrefix("._") { return true }   // AppleDouble
        switch name {
        case ".fseventsd", ".Trashes", ".Spotlight-V100",
             ".TemporaryItems", ".DocumentRevisions-V100":
            return true
        default:
            return false
        }
    }

    /// 目录大小，包含隐藏文件与 AppleDouble（`.fseventsd`、`__MACOSX` 里
    /// 全是这类文件，不能复用压缩统计那套 skipsHiddenFiles）。
    private static func totalSizeIncludingHidden(_ url: URL) -> Int64 {
        var total: Int64 = 0
        var stack: [URL] = [url]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                         .isSymbolicLinkKey, .fileSizeKey]
        while let dir = stack.popLast() {
            guard let names = directoryEntryNames(at: dir.path) else { continue }
            for name in names {
                let child = dir.appendingPathComponent(name)
                let values = try? child.resourceValues(forKeys: keys)
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    stack.append(child)
                } else {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return total
    }

    // MARK: - Extract (UI flows)

    /// 一键解压：位置跟随设置。默认解到归档同级的新文件夹，重名自动加序号。
    func extractAll() {
        guard canStartTask(), let archive = archiveURL else { return }
        guard let dest = extractionDestination(for: archive) else { return }
        extract(archive: archive, to: dest, items: [], status: L("正在解压…"), reveal: true)
    }

    /// 按设置决定「解压」按钮落到哪里。
    /// 默认仍然解到同级的新文件夹——直接铺在源目录旁边，同名文件一多就分不清哪些是刚解出来的。
    private func extractionDestination(for archive: URL) -> URL? {
        let anchor = extractionAnchorURL ?? archive
        switch SettingsStore.shared.extractionTarget {
        case .archiveFolder:
            return uniqueExtractDestination(for: archive)

        case .lastUsed:
            let dir = SettingsStore.shared.lastExtractDirectory ?? anchor.deletingLastPathComponent()
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
                ?? anchor.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
            SettingsStore.shared.lastExtractDirectory = chosen
            return chosen
        }
    }

    /// 手动选择解压位置。
    func extractAllChoosingDestination() {
        guard canStartTask(), let archive = archiveURL else { return }
        let anchor = extractionAnchorURL ?? archive

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("panel.extractTo.message", comment: "选择解压目标文件夹的提示语")
        panel.prompt = NSLocalizedString("panel.extractTo.prompt", comment: "解压目标面板的确认按钮")
        panel.directoryURL = anchor.deletingLastPathComponent()
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
        guard canStartTask(), let archive = archiveURL else { return }
        let anchor = extractionAnchorURL ?? archive
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
            panel.directoryURL = anchor.deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            dest = chosen
        } else {
            // 「解到压缩包所在文件夹」：铺在原始包旁边，重名自动改名，绝不覆盖。
            dest = anchor.deletingLastPathComponent()
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
        guard canStartTask(), let archive = archiveURL, !selection.isEmpty else { return }
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
        guard canStartTask(), let archive = archiveURL else { return }
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
        lastExtractedItems = []

        runTask(
            status: status,
            progress: TaskProgressDescriptor(
                kind: .extract,
                fileName: archive.lastPathComponent,
                totalBytes: Self.byteSize(of: archive)
            )
        ) { [self] in
            await extractBlocking(archive: archive, to: dest, items: items, renameExisting: rename)
        } completion: { code in
            // 空间预检里可能点了「换位置」，实际落点以链路里记下的为准。
            let landed = self.lastExtractDestination ?? dest
            if code == 0 {
                self.progress = 100  // 7zz 不保证打到 100%，成功后补齐。
                self.currentItem = nil
                var text = String(format: L("解压完成 → %@"), landed.path)
                if let note = self.pendingSafetyNote {
                    text += "（\(note)）"
                    self.pendingSafetyNote = nil
                }
                self.statusText = text
                if reveal, SettingsStore.shared.revealAfterExtract {
                    // 目标是新建的解包文件夹：选中里面的产物，或至少打开文件夹内容，
                    // 不再把目录本身交给 select（那会打开它的父目录）。
                    FinderReveal.show(items: self.lastExtractedItems, in: landed)
                }
                self.applyArchiveHandling(archive: archive)
                // 「每次询问」时由弹窗决定关不关窗口，这里先不抢着关。
                // 内层包只是从父包里临时解出来的一层，解完还要留在外层继续浏览，
                // 此时关窗口等于把用户正在看的整个归档丢掉。
                if self.extractCompletionPrompt == nil,
                   SettingsStore.shared.closeAfterExtract,
                   !self.isNestedArchive,
                   self.archiveURL == archive {
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

    // MARK: - 预览

    /// 底栏「预览」能不能点：清单页看本地文件，解压页只认选中的单个文件。
    var canPreviewSelection: Bool {
        let compose = ComposeArchiveState.shared
        if compose.isActive {
            return compose.previewItem != nil
        }
        guard archiveURL != nil, selection.count == 1, let path = selection.first,
              let entry = entries.first(where: { $0.path == path }) else { return false }
        return !entry.isDirectory
    }

    /// 底栏按钮与空格键的统一入口：按当前页面决定预览什么。
    func previewCurrent() {
        let compose = ComposeArchiveState.shared
        if compose.isActive {
            if let item = compose.previewItem {
                QuickLookPreview.shared.present([item.url])
            }
            return
        }
        previewSelectedEntry()
    }

    private var preparingPreview = false

    /// 包内条目不能直接预览：先解到临时目录，再交给系统 QuickLook。
    func previewSelectedEntry() {
        guard !preparingPreview, canStartTask(), let archive = archiveURL,
              selection.count == 1, let path = selection.first,
              let entry = entries.first(where: { $0.path == path }), !entry.isDirectory else { return }

        preparingPreview = true
        let previousStatus = statusText
        statusText = L("正在准备预览…")

        // 密码用现成的：看过一次加密包之后 archivePassword 已经在了，没有就翻密码本。
        let password = archivePassword ?? (SettingsStore.shared.vaultAutoTry
            ? PasswordVault.shared.password(for: archive.lastPathComponent)
            : nil)
        let executable = runner.executableURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<URL, Error>
            do {
                let url = try ArchiveExport.materialize(
                    archive: archive,
                    items: [path],
                    pathInArchive: path,
                    password: password,
                    executable: executable
                )
                outcome = .success(url)
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparingPreview = false
                self.statusText = previousStatus
                switch outcome {
                case .success(let url):
                    QuickLookPreview.shared.present([url])
                case .failure:
                    self.errorMessage = L("这个条目解不出来，所以没法预览")
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
    /// 默认「每次询问」：弹一张卡片让用户自己选，选完再决定窗口去留。
    private func applyArchiveHandling(archive: URL) {
        // 内层包在 /tmp 里，问用户「要不要移入废纸篓」没有意义。
        guard nestedChain.isEmpty else { return }
        switch SettingsStore.shared.archiveHandling {
        case .keep:
            return
        case .trash:
            resolveExtractCompletion(moveToTrash: true, archive: archive)
        case .ask:
            extractCompletionPrompt = ExtractCompletionPrompt(archive: archive)
            // 解压可能刚把访达拉到前台，把 App 拉回来卡片才看得见。
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 卡片上的两个按钮共用这一条收尾路径。
    /// - 移入废纸篓：源包进废纸篓，清空归档状态并关掉主窗口（退出归档页）。
    /// - 保留：什么都不做，继续展示这个归档。
    func resolveExtractCompletion(moveToTrash: Bool, archive: URL? = nil) {
        let target = archive ?? extractCompletionPrompt?.archive
        extractCompletionPrompt = nil
        guard moveToTrash, let target else { return }

        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
        } catch {
            errorMessage = String(format: L("移到废纸篓失败：%@"), error.localizedDescription)
            return
        }
        if archiveURL == target { unloadArchive() }
        MainWindowController.shared.close()
    }

    /// 清空当前归档状态（源包被移走或关闭窗口时用）。
    private func unloadArchive() {
        closeAllNestedArchives()
        archiveURL = nil
        entries = []
        treeNodes = []
        selection = []
        archivePassword = nil
        archiveEncrypted = false
    }

    /// 关闭主窗口：清掉当前归档 / 创建清单，下次打开直接回到欢迎页。
    /// 正在跑任务时不动现场，免得解压到一半把状态抹掉。
    func returnToHome() {
        guard !isBusy else { return }
        unloadArchive()
        allEntries = []
        baseEntries = []
        baseDirty = true
        childrenIndex = [:]
        searchText = ""
        errorMessage = nil
        statusText = L("就绪")
        progress = 0
        currentItem = nil
        extractCompletionPrompt = nil
        revealRequest = nil
        ComposeArchiveState.shared.deactivate()
    }

    /// 访达右键：逐个解压到**压缩包所在文件夹**（右键时的那个「当前目录」）。
    /// 不建窗口、不弹位置选择；已有同名文件由 `-aou` 自动改名，绝不静默覆盖。
    /// - Parameter destination: 非 nil 时全部解到这里（右键「解压到指定目录…」用）。
    /// - Parameter revealResult: 双击归档时为 true——静默解压本来不弹任何界面，
    ///   完成后在访达里把结果选出来，用户才知道文件落在哪（右键任务不打扰，保持 false）。
    func extractAutomatically(_ urls: [URL], to destination: URL? = nil, revealResult: Bool = false) {
        guard !urls.isEmpty else { return }
        guard canStartTask() else { NSSound.beep(); return }

        // 每次任务重来，避免上一次的产物串到这次的「在访达中显示」。
        lastExtractedItems = []
        let archives = urls
        if let destination {
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            SettingsStore.shared.lastExtractDirectory = destination
        }
        // 静默任务和「当前打开的归档」无关，清掉上一份归档的密码状态，
        // 否则会给没加密的包白弹一次密码框。
        archivePassword = nil
        archiveEncrypted = false
        let silent = beginSilentRun()

        runTask(
            status: L("正在解压…"),
            progress: TaskProgressDescriptor(
                kind: .extract,
                fileName: archives[0].lastPathComponent,
                totalBytes: Self.byteSize(of: archives)
            )
        ) { [self] in
            var lastCode: Int32 = 0
            for (index, archive) in archives.enumerated() {
                await MainActor.run {
                    self.statusText = archives.count > 1
                        ? String(format: L("正在解压 (%d/%d)…"), index + 1, archives.count)
                        : L("正在解压…")
                    self.taskProgress?.fileName = archive.lastPathComponent
                }
                // 当前目录 = 压缩包所在目录：内容直接铺在这里，不再多套一层同名文件夹。
                let dest = destination ?? archive.deletingLastPathComponent()
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
                let folder = destination ?? archives[0].deletingLastPathComponent()
                self.statusText = archives.count > 1
                    ? String(format: L("已解压 %d 个归档到当前文件夹"), archives.count)
                    : L("解压完成，文件已放到当前文件夹")
                if revealResult {
                    // 先收起进度浮层，再让访达结果露出来，别让浮层压在新窗口上。
                    self.taskProgress = nil
                    // 传「产物」而不是「目标目录」：否则 activateFileViewerSelecting
                    // 会打开目标目录的父目录并选中它，窗口停在上一层。
                    FinderReveal.show(items: self.lastExtractedItems, in: folder)
                }
                if let used = self.archivePassword, SettingsStore.shared.vaultAutoSave {
                    for archive in archives {
                        PasswordVault.shared.upsert(
                            name: archive.lastPathComponent,
                            password: used,
                            note: ""
                        )
                    }
                }
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
                        revealItems: self.lastExtractedItems,
                        in: folder
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

    /// 访达右键「解压到指定目录…」：先挑目录，挑完仍走静默链路（不建主窗口）。
    /// 用户取消时，如果这个进程是专为这次右键拉起来的，就退出，不留一个空壳。
    func chooseDestinationAndExtract(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("panel.extractTo.message", comment: "选择解压目标文件夹的提示语")
        panel.prompt = NSLocalizedString("panel.extractTo.prompt", comment: "解压目标面板的确认按钮")
        panel.directoryURL = SettingsStore.shared.lastExtractDirectory
            ?? urls[0].deletingLastPathComponent()

        guard panel.runModal() == .OK, let dest = panel.url else {
            MainWindowController.shared.retractIfEmpty()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !MainWindowController.shared.hasShown {
                    NSApp.terminate(nil)
                }
            }
            return
        }
        extractAutomatically(urls, to: dest)
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
        guard canStartTask() else { NSSound.beep(); return }
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
            // 走和 load() 同一条管线：原始条目是 allEntries，列表显示的是 rebuildVisible()
            // 过滤排序后的结果。直接写 entries 会让搜索、排序、辅助项开关读到旧数据。
            self.allEntries = parsed
            self.archiveEncrypted = result.output.contains("Encrypted = +")
            self.baseDirty = true
            self.rebuildVisible()
            let available = Set(self.entries.map { Self.normalizeEntryPath($0.path) })
            let wanted = paths.map(Self.normalizeEntryPath).filter(available.contains)
            if !wanted.isEmpty {
                self.selection = Set(wanted)
                // 拖进的文件夹可能是折叠的：把各级父目录一起交给列表展开，
                // 否则「已添加」的提示下面看不见任何新条目（T-08）。
                var folders: Set<String> = []
                for path in wanted {
                    var parent = (path as NSString).deletingLastPathComponent
                    while !parent.isEmpty {
                        folders.insert(parent)
                        parent = (parent as NSString).deletingLastPathComponent
                    }
                }
                self.revealRequest = RevealRequest(
                    folders: folders.sorted { $0.count < $1.count },
                    entries: wanted
                )
                appDbg("reveal folders=\(folders.sorted()) entries=\(wanted)")
            }
        }
    }

    // MARK: - 包内编辑（T-09）

    /// 当前归档能不能改条目。rar、单流压缩器、分卷包一律不行。
    var canEditCurrentArchive: Bool {
        // 内层包是临时解出来的副本，改了也回不到父包里，所以一律不给改。
        guard let archive = archiveURL, nestedChain.isEmpty else { return false }
        return ArchiveMutator.canEdit(archive)
    }

    private var notEditableMessage: String {
        L("这个归档不能直接改条目。分卷包和 rar 请解压后重新打包。")
    }

    /// 删除选中的条目。选中目录时 7zz 的 `-r` 会连带删掉里面所有东西。
    func deleteEntries(_ paths: [String]) {
        guard canStartTask(), let archive = archiveURL else { NSSound.beep(); return }
        guard canEditCurrentArchive else { errorMessage = notEditableMessage; return }
        let items = paths.map(Self.normalizeEntryPath).filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        guard confirmDelete(items) else { return }

        let base = ["d", archive.path, "-y", "-r", "-bsp1", "-bb1"]
        mutateArchive(base: base, items: items, status: L("正在删除条目…"), selectAfter: []) {
            self.statusText = String(format: L("已删除 %d 项"), items.count)
            self.selection = []
        }
    }

    /// 重命名单个条目。7zz 的 `rn` 会自动把目录下的子项路径一起改掉（实测）。
    func renameEntry(_ path: String) {
        guard canStartTask(), let archive = archiveURL else { NSSound.beep(); return }
        guard canEditCurrentArchive else { errorMessage = notEditableMessage; return }
        let normalized = Self.normalizeEntryPath(path)
        guard !normalized.isEmpty else { return }

        let parent = (normalized as NSString).deletingLastPathComponent
        let original = (normalized as NSString).lastPathComponent
        guard let newName = askNewName(original: original, siblings: childNames(in: parent)) else { return }
        let newPath = parent.isEmpty ? newName : parent + "/" + newName

        let base = ["rn", archive.path, "-y", "-bsp1", "-bb1"]
        mutateArchive(
            base: base,
            items: [normalized, newPath],
            status: L("正在重命名…"),
            selectAfter: [newPath]
        ) {
            self.statusText = String(format: L("已重命名为「%@」"), newName)
        }
    }

    /// 删除 / 重命名共用的执行壳：先备份原包，密码按需补上，失败整份还原。
    private func mutateArchive(
        base: [String],
        items: [String],
        status: String,
        selectAfter: [String],
        onSuccess: @escaping () -> Void
    ) {
        guard let archive = archiveURL else { return }
        let backup: URL
        do {
            backup = try ArchiveMutator.backup(archive)
        } catch {
            errorMessage = String(format: L("备份原包失败，已停止：%@"), error.localizedDescription)
            return
        }

        runTask(status: status) { [self] in
            var password = archivePassword
            if archiveEncrypted, password == nil {
                guard let entered = await askPassword(isRetry: false) else { return 255 }
                password = entered
                archivePassword = entered
            }
            var args = base
            if let password, !password.isEmpty { args.append("-p\(password)") }
            args.append(contentsOf: items)
            return await runWithProgress(args, progressRange: 0...100)
        } completion: { [self] code in
            if code == 0 {
                ArchiveMutator.discard(backup)
                progress = 100
                currentItem = nil
                onSuccess()
                reloadEntries(selecting: selectAfter)
            } else if code == 255 {
                ArchiveMutator.discard(backup)
                statusText = L("已取消")
            } else {
                let restored = ArchiveMutator.restore(archive, from: backup)
                statusText = restored ? L("修改失败，原包已还原") : L("修改失败，原包可能已损坏")
                errorMessage = restored
                    ? Self.describe(exitCode: code)
                    : String(format: L("%@。备份还在 %@"), Self.describe(exitCode: code), backup.path)
            }
        }
    }

    private func confirmDelete(_ items: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? String(format: L("从归档里删除「%@」？"), (items[0] as NSString).lastPathComponent)
            : String(format: L("从归档里删除这 %d 项？"), items.count)
        alert.informativeText = L("会直接改写压缩包，删了没法撤销。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("删除"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 输入框校验不通过就再来一轮，最多四次，不用关掉窗口重新点一次菜单。
    private func askNewName(original: String, siblings: Set<String>) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        var hint = String(format: L("给「%@」换个名字"), original)
        for _ in 0..<4 {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L("重命名")
            alert.informativeText = hint
            alert.addButton(withTitle: L("重命名"))
            alert.addButton(withTitle: L("取消"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = original
            field.bezelStyle = .roundedBezel
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.window.level = .floating
            // 默认只选中主干、不选中扩展名，跟访达一致。
            let ext = (original as NSString).pathExtension
            let selectLength = ext.isEmpty ? (original as NSString).length
                : (original as NSString).length - ext.count - 1
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(0, selectLength))

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let typed = field.stringValue
            if let reason = ArchiveMutator.invalidReason(for: typed, siblings: siblings, original: original) {
                hint = reason
                continue
            }
            return typed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
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

    /// 多选拖出时，把选中的条目摊成拖拽项。
    /// 目录即使没有显式条目（只有子文件）也能认出来，否则拖文件夹会掉项。
    func dragItems(for paths: [String]) -> [MultiDrag.Item] {
        let all = Dictionary(
            entries.map { (Self.normalizeEntryPath($0.path), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return paths.compactMap { raw in
            let path = Self.normalizeEntryPath(raw)
            if let entry = all[path] {
                return MultiDrag.Item(
                    path: path,
                    name: entry.displayName,
                    isDirectory: entry.isDirectory
                )
            }
            let prefix = path + "/"
            guard entries.contains(where: { Self.normalizeEntryPath($0.path).hasPrefix(prefix) }) else {
                return nil
            }
            return MultiDrag.Item(
                path: path,
                name: (path as NSString).lastPathComponent,
                isDirectory: true
            )
        }
    }

    /// 拖拽开始时把上下文拍下来：之后即使用户切了归档，空中的这一批也不受影响。
    var dragContext: MultiDrag.Context {
        MultiDrag.Context(
            archive: archiveURL,
            password: archivePassword,
            executable: runner.executableURL
        )
    }

    // MARK: - Compress (UI flow)

    func compress() {
        guard canStartTask() else { return }

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
        compress(sources: open.urls)
    }

    /// 源已经定好（创建页清单 / 访达右键「压缩为…」），只弹保存面板。
    /// `onStarted` 只在保存面板确认、压缩真的启动后调用；用户取消时清单原样保留。
    func compress(sources: [URL], onStarted: (() -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        guard canStartTask() else { NSSound.beep(); return }

        if let mismatch = options.passwordValidationMessage {
            errorMessage = mismatch
            return
        }

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
        onStarted?()
    }

    /// 访达右键：用当前设置把项目压到第一个项目所在目录（右键时的「当前目录」）。
    /// 不覆盖已有归档：同名时自动追加序号（a.zip → a 2.zip），避免静默丢数据。
    func compressAutomatically(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard canStartTask() else { NSSound.beep(); return }
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

    // MARK: 访达多次调用合并（T-06）

    /// 访达在部分场景下会**逐个**投递 `threxo://compress?path=…`（每个选中项一次），
    /// 直接执行就会生成一串只有一项的包。这里攒 400ms：期间来的请求并进同一批，
    /// 静默期结束才真正压一次。单个文件也就是多等 0.4 秒，换来多选一定只出一个包。
    func enqueueSilentCompress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls where !pendingSilentCompress.contains(where: { $0.path == url.path }) {
            pendingSilentCompress.append(url)
        }
        silentCompressToken += 1
        let token = silentCompressToken

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silentCompressWindow) { [weak self] in
            guard let self, self.silentCompressToken == token else { return }
            let batch = self.pendingSilentCompress
            self.pendingSilentCompress = []
            guard !batch.isEmpty else { return }
            appDbg("compress batch flush \(batch.count)")
            self.compressAutomatically(batch)
        }
    }

    /// 访达右键「压缩为…」：先把主窗口立起来，再切到文件清单页并预填这些源。
    /// 用户可以在清单里继续加、删，保存时才进入参数向导与系统保存面板。
    func beginCompressDialog(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        MainWindowController.shared.show()
        // 冷启动时窗口上屏要一点时间，实测 150ms 稳。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ComposeArchiveState.shared.activate(sources: urls)
        }
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

        runTask(
            status: L("正在压缩…"),
            progress: TaskProgressDescriptor(
                kind: .compress,
                fileName: dest.lastPathComponent,
                totalBytes: 0,
                // 源可能是几十万个小文件的文件夹，递归统计放到后台算。
                sizeProvider: { Self.byteSize(of: sources) }
            )
        ) { [self] in
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
                if !self.options.password.isEmpty, SettingsStore.shared.vaultAutoSave {
                    PasswordVault.shared.upsert(
                        name: produced.lastPathComponent,
                        password: self.options.password,
                        note: ""
                    )
                }
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
        to destination: URL,
        items: [String],
        renameExisting: Bool = false,
        silent: Bool = false
    ) async -> Int32 {
        var dest = destination
        var renameExisting = renameExisting
        lastExtractDestination = destination

        if archivePassword == nil, SettingsStore.shared.vaultAutoTry,
           let saved = PasswordVault.shared.password(for: archive.lastPathComponent) {
            archivePassword = saved
        }

        // 已知有加密条目但还没拿到密码：先问，省掉一次必然失败的解压。
        if archiveEncrypted, archivePassword == nil {
            guard let entered = await askPassword(isRetry: false) else { return 255 }
            archivePassword = entered
        }

        // 只列一次目录：路径预检、空间核算、危险类型扫描都吃这一份结果。
        // 大归档列一遍要几百毫秒，列两遍纯属浪费。
        let listing = await runSync([
            "l", "-slt", "-ba", "-p\(archivePassword ?? "")", archive.path,
        ])
        // 列不出来（头部加密、损坏、分卷缺失）就不拦，交给 7-Zip 自己报错，免得误伤。
        let scanned = listing.code == 0 ? ArchiveLister.parse(listing.output) : []

        // 路径预检：`/etc/x` 这种条目会被 7-Zip 静默搬到 `<目标>/etc/x`，
        // 用户只会看到凭空多出来的目录，所以先问一句再动手。
        if let blocked = screenEntryPaths(entries: scanned, archive: archive, items: items, silent: silent) {
            return blocked
        }

        // 空间与危险类型预检（T-07）。可能把目标换到别处，所以在这里而不是调用方。
        switch preflight(entries: scanned, archive: archive, items: items, dest: dest, silent: silent) {
        case .abort(let code):
            return code
        case .ok(let resolved):
            dest = resolved
            lastExtractDestination = resolved
            if resolved != destination, !renameExisting {
                // 目标被换到了别的目录：那里有没有同名文件、要不要覆盖，用户没被问过，
                // 所以一律改名落地，不在没确认过的地方覆盖任何东西。
                renameExisting = true
            }
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

        if result.code == 0 {
            // 记下真正落地的顶层产物（用目录差异，-aou 自动改名后也能拿到真实名字）。
            // 完成后在访达里选中「产物」，而不是把目标目录交给 activateFileViewerSelecting：
            // 后者传目录会打开它的父目录并选中该目录，窗口就会停在上一层。
            lastExtractedItems.append(contentsOf: added.map { dest.appendingPathComponent($0) })
        }

        return result.code
    }

    /// 解压前的路径预检。
    /// - Returns: 需要中止时返回退出码；`nil` 表示放行。
    private func screenEntryPaths(
        entries: [ArchiveEntry],
        archive: URL,
        items: [String],
        silent: Bool
    ) -> Int32? {
        guard !entries.isEmpty else { return nil }

        let findings = ArchiveSafety.inspect(entries: entries, items: items)
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

    // MARK: - 空间预检与危险类型提示（T-07）

    /// 解压前要看两件事：
    ///   1. 目标卷装不装得下（10GB 的包解到剩 2GB 的盘上，跑到一半才失败最难受）；
    ///   2. 里面有没有 `.app`/`.pkg`/`.command` 这类「双击就执行」的东西。
    /// 两条都不阻断，只是先让人知道。静默链路不弹窗，结论写进结果通知。
    private enum PreflightOutcome {
        case ok(URL)
        case abort(Int32)
    }

    /// 这些后缀解出来后双击就会执行，来源不明时值得提醒一句。
    private static let executableExtensions: Set<String> = [
        "app", "pkg", "command", "sh", "terminal", "mpkg", "workflow",
    ]

    private func preflight(
        entries: [ArchiveEntry],
        archive: URL,
        items: [String],
        dest: URL,
        silent: Bool
    ) -> PreflightOutcome {
        guard !entries.isEmpty else { return .ok(dest) }

        let wanted = Set(items.map(Self.normalizeEntryPath))
        var needed: Int64 = 0
        var executables: [String] = []

        for entry in entries where !entry.isDirectory {
            let path = Self.normalizeEntryPath(entry.path)
            if !wanted.isEmpty,
               !wanted.contains(path),
               !wanted.contains(where: { path.hasPrefix($0 + "/") }) {
                continue
            }
            needed += entry.size
            if Self.executableExtensions.contains((path as NSString).pathExtension.lowercased()) {
                executables.append(path)
            }
        }

        let free = Self.freeSpace(at: dest)
        appDbg("preflight needed=\(needed) free=\(free ?? -1) exe=\(executables.count) dest=\(dest.path)")

        if !executables.isEmpty {
            if silent {
                appendSafetyNote(String(
                    format: L("含 %d 个可执行文件（%@）"),
                    executables.count,
                    executables.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                ))
            } else if !confirmExecutableEntries(executables) {
                return .abort(255)
            }
        }

        guard needed > 0, let free, needed > free else {
            return .ok(dest)
        }

        if silent {
            pendingSafetyFailure = String(
                format: L("空间不足：解压需要 %@，目标卷可用 %@。"),
                ByteFormatter.string(needed), ByteFormatter.string(free)
            )
            return .abort(Self.exitInsufficientSpace)
        }

        switch askInsufficientSpace(needed: needed, free: free) {
        case .proceed:
            return .ok(dest)
        case .cancel:
            return .abort(255)
        case .elsewhere:
            guard let chosen = pickExtractDestination(startingAt: dest) else { return .abort(255) }
            try? FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
            SettingsStore.shared.lastExtractDirectory = chosen
            return .ok(chosen)
        }
    }

    /// 目标路径所在卷的可用空间。路径还不存在时退到父目录再问。
    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        if !FileManager.default.fileExists(atPath: url.path) {
            probe = url.deletingLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? probe.resourceValues(forKeys: keys) else { return nil }
        // forImportantUsage 会把「可清理的缓存」也算进可用空间，比 volumeAvailableCapacity 更接近
        // 访达显示的数字，优先用它。但它在某些卷（只读盘、DMG、网络卷）上会返回 0，
        // 那就退回普通可用空间，别把「未知」当成「一点都没有」。
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 {
            return bytes
        }
        if let bytes = values.volumeAvailableCapacity { return Int64(bytes) }
        return nil
    }

    private enum SpaceChoice {
        case proceed
        case elsewhere
        case cancel
    }

    private func askInsufficientSpace(needed: Int64, free: Int64) -> SpaceChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("目标位置空间不足")
        alert.informativeText = String(
            format: L("解压后需要 %@，目标卷可用 %@。可以换个位置，或仍然解压（可能中途失败）。"),
            ByteFormatter.string(needed), ByteFormatter.string(free)
        )
        alert.addButton(withTitle: L("换位置…"))
        alert.addButton(withTitle: L("仍然解压"))
        alert.addButton(withTitle: L("取消"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .elsewhere
        case .alertSecondButtonReturn: return .proceed
        default: return .cancel
        }
    }

    /// 选一个新目标目录。默认落在当前目标所在目录，方便顺手挑个外接盘。
    private func pickExtractDestination(startingAt current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("panel.extractTo.message", comment: "选择解压目标文件夹的提示语")
        panel.prompt = NSLocalizedString("panel.extractTo.prompt", comment: "解压目标面板的确认按钮")
        panel.directoryURL = current
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 归档里有可执行文件：提醒一句，默认按钮是继续（不阻断）。
    private func confirmExecutableEntries(_ paths: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let names = paths.prefix(5).map { ($0 as NSString).lastPathComponent }
        let sample = names.joined(separator: "、") + (paths.count > names.count ? " 等" : "")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = paths.count == 1
            ? L("归档里有一个可执行文件")
            : String(format: L("归档里有 %d 个可执行文件"), paths.count)
        alert.informativeText = String(
            format: L("%@ 解出来后双击就会运行。确认来源可靠再打开。"),
            sample
        )
        alert.addButton(withTitle: L("继续解压"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
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
                                self.noteActivity()
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
                                self.noteActivity()
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
    ///
    /// 这条路径也要登记 `activeProcess`：列一个几万条的归档可能要几百毫秒到几秒，
    /// 卡死判定靠「有没有子进程」来区分「真在跑」和「永远回不来」，漏登记就会误判。
    private func runSync(_ args: [String]) async -> (code: Int32, output: String, error: String) {
        let runner = self.runner
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = (try? runner.runCollecting(
                    arguments: args,
                    onStart: { process in
                        DispatchQueue.main.async {
                            self?.activeProcess = process
                            self?.noteActivity()
                        }
                    }
                )) ?? (code: -1, output: "", error: "")
                DispatchQueue.main.async {
                    guard let self else { return }
                    // 只清掉自己那一个：期间可能已经有新进程接管了这个字段。
                    if self.activeProcess?.isRunning == false {
                        self.activeProcess = nil
                    }
                    self.noteActivity()
                }
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

    /// 记一次「有进展」，卡死判定用。
    private func noteActivity() {
        lastTaskActivity = Date()
    }

    /// 新任务能不能开工。开工前顺手检查上一次是不是卡死了。
    ///
    /// 只要 `isBusy` 为真、又没有子进程在跑、也没有在等用户输密码，
    /// 那么这个任务实际上不可能再往前推——它的 `continuation` 丢了。
    /// 不在这里复位，后续所有入口都会被 `isBusy` 挡掉，用户看到的就是「点了没反应」。
    func canStartTask() -> Bool {
        _ = recoverIfStalled()
        return !isBusy
    }

    /// 菜单栏「复位」是否可用：有任务挂着，但既没有进程在跑、也没有在等密码。
    var canResetStalledTask: Bool {
        guard isBusy else { return false }
        guard passwordContinuation == nil, passwordPrompt == nil else { return false }
        return !(activeProcess?.isRunning ?? false)
    }

    /// 复位卡住的任务。
    /// - Parameter force: 菜单栏手动点击时为 true，跳过 20 秒静默期；自动判定走默认值。
    /// - Returns: 是否真的做了复位。
    @discardableResult
    func recoverIfStalled(force: Bool = false) -> Bool {
        guard isBusy else { return false }
        // 正在等用户输密码：这是正常等待，不是卡死，不能替他取消。
        guard passwordContinuation == nil, passwordPrompt == nil else { return false }
        if let process = activeProcess, process.isRunning { return false }
        let idle = Date().timeIntervalSince(lastTaskActivity)
        guard force || idle > Self.stallTimeout else { return false }

        appDbg("recover stalled task idle=\(Int(idle))s status=\(statusText)")
        let wasSilent = silentRun
        isBusy = false
        progress = 0
        currentItem = nil
        statusText = L("上一个任务没有正常结束，已复位")
        // 静默任务卡在这里时进程不会自己退出（收尾逻辑永远等不到），
        // 复位后按「任务已结束」收尾，让这个可能已经没用的进程退掉。
        if wasSilent {
            silentRun = false
            AppDelegate.shared?.endHeadlessJob()
        }
        return true
    }

    /// Runs `work` off-main with the busy spinner, then calls `completion` on main.
    /// - Parameter progress: 非 nil 表示这是压缩 / 解压任务，展示统一进度弹窗；
    ///   不传的任务（列目录、加文件、改包）沿用底栏的小进度条，不弹浮层。
    private func runTask(
        status: String,
        progress descriptor: TaskProgressDescriptor? = nil,
        work: @escaping @MainActor () async -> Int32,
        completion: @escaping @MainActor (Int32) -> Void
    ) {
        isBusy = true
        progress = 0
        errorMessage = nil
        currentItem = nil
        statusText = status
        noteActivity()
        if let descriptor { beginTaskProgress(descriptor, phase: status) }
        Task.detached(priority: .userInitiated) {
            let code = await work()
            await MainActor.run {
                self.activeProcess = nil
                self.noteActivity()
                self.isBusy = false
                // completion 里会改 status/progress（压缩成功后还会 load 新归档），
                // 先把这份浮层标记结束，别让那些状态把补满的 100% 打回 0%。
                let finishing = self.taskProgress
                finishing?.finished = true
                completion(code)
                self.endTaskProgress(finishing)
            }
        }
    }

    func cancel() {
        activeProcess?.terminate()
    }

    // MARK: - 统一进度弹窗

    /// 任务开始：建一份可观察状态，驱动浮层。总量若在后台才算得出来，
    /// 先只显示百分比，算完回填，绝不让「统计文件夹大小」拖慢弹窗出现。
    private func beginTaskProgress(_ descriptor: TaskProgressDescriptor, phase: String) {
        let state = TaskProgressState(
            kind: descriptor.kind,
            fileName: descriptor.fileName,
            totalBytes: descriptor.totalBytes,
            percent: 0,
            phase: phase
        )
        taskProgress = state
        appDbg("taskProgress show kind=\(descriptor.kind) file=\(descriptor.fileName) "
               + "total=\(descriptor.totalBytes) sizeProvider=\(descriptor.sizeProvider != nil)")
        guard let provider = descriptor.sizeProvider else { return }
        DispatchQueue.global(qos: .utility).async {
            let total = provider()
            DispatchQueue.main.async { [weak self, weak state] in
                guard let self, let state, self.taskProgress === state else { return }
                state.totalBytes = total
            }
        }
    }

    /// 任务结束：补满进度，留 0.55 秒让人看清 100% 再淡出。
    /// 已经弹出「原包要不要移入废纸篓」或密码框时立刻收起，免得浮层挡住对话框。
    private func endTaskProgress(_ state: TaskProgressState?) {
        guard let state else { return }
        appDbg("taskProgress hide kind=\(state.kind) file=\(state.fileName) percent=100")
        state.percent = 100
        state.currentItem = nil
        state.finished = true
        if extractCompletionPrompt != nil || passwordPrompt != nil {
            // 弹了询问卡片 / 密码框就立刻收，别让浮层压在对话框上。
            if taskProgress === state { taskProgress = nil }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            // 期间若已有新任务接管浮层，这个延时不能把人家的弹窗关掉。
            guard let self, self.taskProgress === state else { return }
            self.taskProgress = nil
        }
    }

    /// 弹窗「取消」：真实任务终止 7zz；调试态没有进程时直接收起浮层。
    func cancelProgressTask() {
        if isBusy {
            cancel()
        } else {
            taskProgress = nil
        }
    }

    /// 仅调试：`threxo://progressDemo?kind=compress&percent=58&total=…&name=…&hold=6`
    /// 静态展示浮层，便于截图核对布局与深色模式。不启动任何进程。
    func debugProgressDemo(kind: TaskProgressKind, percent: Int, totalBytes: Int64,
                           fileName: String, hold: TimeInterval) {
        let state = TaskProgressState(kind: kind, fileName: fileName,
                                      totalBytes: totalBytes, percent: percent,
                                      phase: kind.title)
        taskProgress = state
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard self?.taskProgress === state else { return }
            self?.taskProgress = nil
        }
    }

    /// 磁盘上的实际大小。目录递归统计，只在后台线程调用。
    static func byteSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in enumerator {
                let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v?.isRegularFile == true else { continue }
                total += Int64(v?.fileSize ?? 0)
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    static func byteSize(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { $0 + Self.byteSize(of: $1) }
    }

    // MARK: - URL scheme (threxo://extract|compress?path=…)

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "threxo" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let paths = components?.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        appDbg("handleIncomingURL host=\(url.host ?? "nil") paths=\(urls.count) busy=\(isBusy) idle=\(Int(Date().timeIntervalSince(lastTaskActivity)))s")
        switch url.host {
        case "progressDemo":
            // 仅调试：按指定百分比静态展示进度弹窗，用来核对视觉与取消按钮。
            let query = components?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            debugProgressDemo(
                kind: value("kind") == "extract" ? .extract : .compress,
                percent: Int(value("percent") ?? "") ?? 58,
                totalBytes: Int64(value("total") ?? "") ?? 568_720_000,
                fileName: value("name") ?? "SP-AMR-CUSTOM_V08-beta1.zip",
                hold: Double(value("hold") ?? "") ?? 6
            )
        case "progressCancel":
            // 仅调试：等价于点弹窗里的「取消」，验证取消后浮层立即收起。
            cancelProgressTask()
        case "extract":
            extractAutomatically(urls)
        case "extractReveal":
            // 仅调试：复现「双击归档 → 静默解压 → 在访达显示结果」的完整链路。
            extractAutomatically(urls, revealResult: true)
        case "extractTo":
            // 右键「解压到指定目录…」：先让用户挑目录，挑完静默解。
            chooseDestinationAndExtract(urls)
        case "compress":
            // 访达可能逐个投递，攒 400ms 再动手，多选只出一个包。
            enqueueSilentCompress(urls)
        case "compressDialog":
            beginCompressDialog(urls)
        case "cleanmaceutils":
            cleanMacAuxiliaryFiles(in: urls)
        case "add":
            #if DEBUG
            debugAdd(url)
            #endif
        #if DEBUG
        case "debugExtractTo":
            // 仅调试：`threxo://debugExtractTo?dest=/Volumes/小盘&path=…`
            // 绕过目录选择面板，直接验证空间预检 / 危险类型这些静默链路分支。
            let dest = components?.queryItems?.first(where: { $0.name == "dest" })?.value
            extractAutomatically(urls, to: dest.map { URL(fileURLWithPath: $0) })
        #endif
        #if DEBUG
        case "about":
            // 仅调试：脚本里验一下关于/许可页能正常渲染，Release 不存在这个入口。
            AboutWindowController.shared.show()
        case "reset":
            // 仅调试：不用碰菜单栏就能复现 / 验证卡死复位这条路径。
            appDbg("debug reset forced=\(recoverIfStalled(force: true))")
        case "stall":
            // 仅调试：造一个「isBusy 卡死」的现场（没有进程、没有等待），验证自动复位。
            guard !isBusy else { break }
            isBusy = true
            statusText = L("模拟卡死")
            appDbg("debug stall injected")
        case "debugEdit":
            // 仅调试：绕过确认弹窗，验证「备份 → 7zz d/rn → 回读」整条链路。
            debugEdit(url)
        case "onboarding":
            // 仅调试：`threxo://onboarding?step=3` 直接落到某一页，方便截图核对布局。
            let raw = components?.queryItems?.first(where: { $0.name == "step" })?.value
            OnboardingWindowController.shared.show(step: raw.flatMap { Int($0) })
        case "mainwindow":
            // 仅调试：不跑向导直接看主窗口空态。
            MainWindowController.shared.show()
        case "centerWindow":
            // 仅调试：窗口落在扩展桌面时，截图工具抓不到，挪回主屏再看。
            if let screen = NSScreen.screens.first,
               let target = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                let area = screen.visibleFrame
                let size = target.frame.size
                target.setFrameOrigin(NSPoint(x: area.minX + (area.width - size.width) / 2,
                                              y: area.minY + (area.height - size.height) / 2))
            }
        case "compose":
            // 仅调试：`threxo://compose?path=…` 直接进创建清单页，可带预填源。
            MainWindowController.shared.show()
            ComposeArchiveState.shared.activate(sources: urls)
            // 仅调试：`&sel=0` / `&sel=1,2` 预选清单项、`&layout=icon` 切图标视图，
            // 用来核对右侧详情栏与两种版式。
            if let layoutRaw = components?.queryItems?.first(where: { $0.name == "layout" })?.value,
               let layout = ComposeLayout(rawValue: layoutRaw) {
                ComposeArchiveState.shared.layout = layout
            }
            // 仅调试：`&col=2` 预先把某个文件夹在分栏视图里展开。
            if let colRaw = components?.queryItems?.first(where: { $0.name == "col" })?.value,
               let index = Int(colRaw), index >= 0, index < ComposeArchiveState.shared.items.count {
                let state = ComposeArchiveState.shared
                let item = state.items[index]
                if item.isDirectory {
                    state.select(item.id)
                    state.columnPath = [item.id]
                    state.loadChildren(of: item.id)
                }
            }
            if let selRaw = components?.queryItems?.first(where: { $0.name == "sel" })?.value {
                let state = ComposeArchiveState.shared
                let picked = selRaw.split(separator: ",")
                    .compactMap { Int($0) }
                    .filter { $0 >= 0 && $0 < state.items.count }
                    .map { state.items[$0].id }
                if !picked.isEmpty { state.selection = Set(picked) }
            }
        case "openNested":
            // 仅调试：`threxo://openNested?path=<包内路径>` 直接打开内嵌压缩包。
            guard let nestedPath = components?.queryItems?.first(where: { $0.name == "path" })?.value else { break }
            MainWindowController.shared.show()
            openNestedArchive(path: nestedPath)
        case "closeNested":
            // 仅调试：退回外层；带 `?to=0` 时按面包屑下标退到指定层。
            if let raw = components?.queryItems?.first(where: { $0.name == "to" })?.value,
               let keep = Int(raw) {
                popNestedArchives(keeping: keep)
            } else {
                closeNestedArchive()
            }
        case "preview":
            // 仅调试：`threxo://preview?path=<包内路径>` 选中该条目并走一次预览。
            guard let entryPath = components?.queryItems?.first(where: { $0.name == "path" })?.value else { break }
            MainWindowController.shared.show()
            selection = [entryPath]
            previewCurrent()
        case "composeSave":
            // 仅调试：验证「保存 → 参数向导」这一步（空清单时不会弹）。
            MainWindowController.shared.show()
            if !ComposeArchiveState.shared.items.isEmpty {
                ComposeArchiveState.shared.showWizard = true
            }
        case "load":
            // 仅调试：不经过 odoc（避开「双击快速解压」设置）直接把归档读进窗口。
            guard let target = urls.first else { break }
            MainWindowController.shared.show()
            load(archive: target)
        case "debugAnchor":
            // 仅调试：核对嵌套包的解压锚点，确保不会解到 /tmp/ThrexoDrop-* 里。
            appDbg("debugAnchor current=\(archiveURL?.path ?? "-") "
                   + "anchor=\(extractionAnchorURL?.path ?? "-") "
                   + "dest=\(archiveURL.map { uniqueExtractDestination(for: $0).path } ?? "-") "
                   + "nested=\(nestedChain.count)")
        case "receiveFiles":
            // 仅调试：等价于把文件 / 文件夹拖进窗口或拖到 Dock（走 receiveOpenFiles）。
            MainWindowController.shared.show()
            receiveOpenFiles(urls)
            appDbg("debug receiveFiles count=\(urls.count) "
                   + "compose=\(ComposeArchiveState.shared.isActive) "
                   + "items=\(ComposeArchiveState.shared.items.count)")
        case "home":
            // 仅调试：等价于点解压页左上角的「返回」，验证回到欢迎页。
            MainWindowController.shared.show()
            returnToHome()
            appDbg("debug home archive=\(archiveURL?.path ?? "nil") "
                   + "compose=\(ComposeArchiveState.shared.isActive)")
        case "closeWindow":
            // 仅调试：验证红绿灯关窗会清掉现场、回到欢迎页。
            MainWindowController.shared.close()
            appDbg("debug closeWindow archive=\(archiveURL?.path ?? "nil") "
                   + "compose=\(ComposeArchiveState.shared.isActive)")
        case "extractAll":
            // 仅调试：走真实的窗口链路解压，验证完成后会自动弹询问卡片。
            MainWindowController.shared.show()
            extractAll()
        case "debugCompressTo":
            // 仅调试：跳过系统保存面板，复现「页面内保存压缩包」后的压缩阶段。
            guard let first = urls.first else { break }
            let destPath = components?.queryItems?.first(where: { $0.name == "dest" })?.value
                ?? first.deletingLastPathComponent().appendingPathComponent("页面压缩测试.zip").path
            MainWindowController.shared.show()
            compress(sources: urls, to: URL(fileURLWithPath: destPath))
        case "debugCores":
            // 仅调试：核对本机核心数、可选档位与当前默认档。
            appDbg("debugCores physical=\(SettingsStore.coreCount) "
                   + "options=\(SettingsStore.coreOptions) "
                   + "maxThreads=\(SettingsStore.shared.maxThreads)")
            // 再把设置窗口里下拉控件的真实选项打出来，验证 1…n 全都上了屏。
            if let root = NSApp.windows.first(where: { $0.title == L("千梭设置") })?.contentView {
                func popups(_ view: NSView) -> [NSPopUpButton] {
                    var out: [NSPopUpButton] = []
                    if let p = view as? NSPopUpButton { out.append(p) }
                    for sub in view.subviews { out += popups(sub) }
                    return out
                }
                for (index, p) in popups(root).enumerated() {
                    appDbg("debugCores popup[\(index)]=\(p.itemTitles.joined(separator: ","))"
                           + " selected=\(p.titleOfSelectedItem ?? "-")")
                }
            }
        case "extractDone":
            // 仅调试：模拟解压完成卡片，`threxo://extractDone?path=…`。
            guard let archive = urls.first else { break }
            MainWindowController.shared.show()
            extractCompletionPrompt = ExtractCompletionPrompt(archive: archive)
        case "extractResolve":
            // 仅调试：`?trash=1|0` 分别验证卡片的两个按钮。
            let trash = components?.queryItems?.first(where: { $0.name == "trash" })?.value == "1"
            resolveExtractCompletion(moveToTrash: trash)
        case "onboardingFinish":
            // 仅调试：验证「跳过设置 / 开始使用」走的收尾逻辑。
            OnboardingWindowController.shared.finish()
        case "vaultTest":
            // 仅调试：验证钥匙串写入 / 读回 / 删除。
            let q = components?.queryItems ?? []
            let name = q.first(where: { $0.name == "name" })?.value ?? "测试归档.zip"
            let pwd = q.first(where: { $0.name == "pwd" })?.value ?? ""
            if q.first(where: { $0.name == "op" })?.value == "clear" {
                PasswordVault.shared.remove(name: name)
            } else if !pwd.isEmpty {
                PasswordVault.shared.upsert(name: name, password: pwd, note: "调试写入")
            }
            let vault = PasswordVault.shared
            appDbg("vaultTest count=\(vault.entries.count) hit=\(vault.password(for: name) ?? "nil") err=\(vault.lastError ?? "none")")
        case "formatTest":
            // 仅调试：验证格式关联的接管与还原（只在冷门后缀上跑，跑完立刻还原）。
            let q = components?.queryItems ?? []
            let ext = q.first(where: { $0.name == "ext" })?.value ?? "lzma"
            let on = q.first(where: { $0.name == "on" })?.value == "1"
            let item = SettingsStore.shared.currentFormatBindings().first { $0.primaryExtension == ext }
            if let item {
                Task { @MainActor in
                    let error = await SettingsStore.shared.setFormatBinding(item, enabled: on)
                    let after = SettingsStore.shared.currentFormatBindings().first { $0.id == item.id }
                    appDbg("formatTest ext=\(ext) on=\(on) err=\(error ?? "none") isDefault=\(after?.isDefault ?? false)")
                }
            } else {
                appDbg("formatTest ext=\(ext) not found")
            }
        case "settings":
            // 仅调试：`threxo://settings?page=extract` 直接落到某一页，方便逐页核对布局。
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let page = query?.first(where: { $0.name == "page" })?.value
            SettingsWindowController.shared.show(page: SettingsPage(rawValue: page ?? "") ?? .general)
            // 仅调试：拉高窗口，一张截图就能看完长设置页底部的「处理器使用」卡片。
            if let height = query?.first(where: { $0.name == "height" })?.value.flatMap(Double.init),
               let panel = NSApp.windows.first(where: { $0.title == L("千梭设置") }) {
                var frame = panel.frame
                let oldHeight = frame.size.height
                frame.size.height = CGFloat(height)
                frame.origin.y = max(0, frame.origin.y - (CGFloat(height) - oldHeight))
                panel.setFrame(frame, display: true)
                panel.center()   // 调试截图用：别让窗口停在屏幕边缘，screencapture 会拍不到
            }
            // 仅调试：把长设置页滚到底，便于截图核对「处理器使用」卡片。
            if query?.first(where: { $0.name == "scroll" })?.value == "bottom",
               let root = NSApp.windows.first(where: { $0.title == L("千梭设置") })?.contentView {
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    var out: [NSScrollView] = []
                    if let s = view as? NSScrollView { out.append(s) }
                    for sub in view.subviews { out += scrollViews(sub) }
                    return out
                }
                for s in scrollViews(root) {
                    let documentHeight = s.documentView?.bounds.height ?? 0
                    let bottom = max(0, documentHeight - s.contentView.bounds.height)
                    s.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                    s.reflectScrolledClipView(s.contentView)
                }
            }
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
    /// 仅调试：`threxo://debugEdit?archive=…&op=delete|rename&path=…&name=…`
    private func debugEdit(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let archivePath = items.first(where: { $0.name == "archive" })?.value,
              let op = items.first(where: { $0.name == "op" })?.value,
              let path = items.first(where: { $0.name == "path" })?.value else { return }
        let archive = URL(fileURLWithPath: archivePath)
        let name = items.first(where: { $0.name == "name" })?.value
        // fail=1 时故意塞一个 7zz 不认识的开关，用来验证「失败整份还原」。
        let fail = items.contains { $0.name == "fail" && $0.value == "1" }
        let confirmSwitch = fail ? "-badswitch" : "-y"

        Task { @MainActor in
            let result = await self.list(archive, password: nil)
            guard result.code == 0 else {
                appDbg("debugEdit 读取失败 code=\(result.code)")
                return
            }
            self.archiveURL = archive
            self.allEntries = ArchiveLister.parse(result.output)
            self.baseDirty = true
            self.rebuildVisible()
            appDbg("debugEdit op=\(op) path=\(path) entries=\(self.allEntries.count)")

            if op == "delete" {
                let base = ["d", archive.path, confirmSwitch, "-r", "-bsp1", "-bb1"]
                self.mutateArchive(base: base, items: [path], status: "debug delete", selectAfter: []) {
                    appDbg("debugEdit delete done")
                }
            } else if op == "rename", let name {
                let parent = (path as NSString).deletingLastPathComponent
                let newPath = parent.isEmpty ? name : parent + "/" + name
                let base = ["rn", archive.path, confirmSwitch, "-bsp1", "-bb1"]
                self.mutateArchive(base: base, items: [path, newPath], status: "debug rename",
                                   selectAfter: [newPath]) {
                    appDbg("debugEdit rename done")
                }
            }
        }
    }

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
            // 上一个密码框还没回话就被新请求顶掉时，先把旧的按「取消」收尾。
            // 直接覆盖会让旧 continuation 永远等不到 resume，它所在的任务就再也回不来。
            passwordContinuation?.resume(returning: nil)
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

        let field: NSTextField = SettingsStore.shared.showPasswordByDefault
            ? NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            : NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("密码")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // 静默链路里 App 可能不是前台的，普通层级的窗口会被别的 App 盖住，
        // 看起来就是「点了右键没反应」。抬到浮动层，保证一定看得见。
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)

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
        // 位置跟外层原始包，名字跟当前正在看的这一层（内嵌包用自己的名字更直观）。
        let dir = (extractionAnchorURL ?? archive).deletingLastPathComponent()
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
