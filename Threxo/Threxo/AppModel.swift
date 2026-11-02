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
/// Also handles `threxo://extract|compress` URL-scheme invocations from FinderSync
/// and Finder double-click / Dock drops via `receiveOpenFiles`.
final class AppModel: ObservableObject {
    /// 单例：AppDelegate 的 openFiles 回调需要一个稳定入口。
    static let shared = AppModel()

    @Published var archiveURL: URL?
    @Published var entries: [ArchiveEntry] = []
    /// 层级树；条目过多时为空，界面回退到扁平列表。
    @Published var treeNodes: [ArchiveNode] = []
    /// 选中的条目路径（与 ArchiveNode.id 一致）。
    @Published var selection: Set<String> = []

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
    /// 归档是否含加密条目（来自 `l -slt` 的 `Encrypted = +`）。
    private var archiveEncrypted = false
    private var passwordContinuation: CheckedContinuation<String?, Never>?

    private var activeProcess: Process?
    private let runner: SevenZipRunner

    struct PasswordPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        guard let url = Bundle.main.url(forResource: "7zz", withExtension: nil) else {
            fatalError("7zz not bundled")
        }
        runner = SevenZipRunner(executableURL: url)
        refreshFinderExtensionState()
    }

    // MARK: - Derived state

    var totalUncompressedSize: Int64 {
        entries.reduce(0) { $0 + $1.size }
    }

    var fileCount: Int {
        entries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
    }

    var hasSelection: Bool { !selection.isEmpty }

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
        entries = []
        treeNodes = []
        selection = []
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
        let parsed = ArchiveLister.parse(result.output)
        entries = parsed
        treeNodes = ArchiveTree.build(parsed)
        let files = parsed.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
        statusText = String(format: L("已加载 %@ · %d 个文件"), url.lastPathComponent, files)
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

    /// 一键解压：解到归档同级的同名文件夹，重名自动加序号，不弹任何面板。
    func extractAll() {
        guard !isBusy, let archive = archiveURL else { return }
        let dest = uniqueExtractDestination(for: archive)
        extract(archive: archive, to: dest, items: [], status: L("正在解压…"), reveal: true)
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

    private func extract(archive: URL, to dest: URL, items: [String], status: String, reveal: Bool) {
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        runTask(status: status) { [self] in
            await extractBlocking(archive: archive, to: dest, items: items)
        } completion: { code in
            if code == 0 {
                self.progress = 100  // 7zz 不保证打到 100%，成功后补齐。
                self.currentItem = nil
                self.statusText = String(format: L("解压完成 → %@"), dest.path)
                if reveal {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } else {
                self.statusText = code == 255 ? L("已取消") : L("解压失败")
                if code != 255 {
                    self.errorMessage = Self.describe(exitCode: code)
                }
            }
        }
    }

    /// FinderSync flow: extract each archive into a sibling folder named after it.
    func extractAutomatically(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        let archives = urls
        runTask(status: L("正在解压…")) { [self] in
            var lastCode: Int32 = 0
            for (index, archive) in archives.enumerated() {
                await MainActor.run {
                    self.statusText = archives.count > 1
                        ? String(format: L("正在解压 (%d/%d)…"), index + 1, archives.count)
                        : L("正在解压…")
                }
                let dest = uniqueExtractDestination(for: archive)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                lastCode = await extractBlocking(archive: archive, to: dest, items: [])
                if lastCode != 0 { break }
            }
            return lastCode
        } completion: { code in
            if code == 0 {
                self.progress = 100
                self.currentItem = nil
                self.statusText = archives.count > 1
                    ? String(format: L("已完成 %d 个归档的解压"), archives.count)
                    : L("解压完成")
            } else {
                self.statusText = code == 255 ? L("已取消") : L("解压失败")
                if code != 255 { self.errorMessage = Self.describe(exitCode: code) }
            }
        }
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

    /// FinderSync flow: 用当前设置把项目压到第一个项目旁边。
    /// 不覆盖已有归档：同名时自动追加序号（a.zip → a 2.zip），避免静默丢数据。
    func compressAutomatically(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        let dir = urls[0].deletingLastPathComponent()
        let base = Self.defaultArchiveBase(for: urls)
        let ext = options.format.fileExtension

        var dest = dir.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        compress(sources: urls, to: dest)
    }

    private func compress(sources: [URL], to dest: URL) {
        // 勾了「压缩完成后删源文件」时先确认一次，默认按钮是取消。
        guard confirmSourceRemovalIfNeeded(sources: sources) else { return }

        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        runTask(status: L("正在压缩…")) { [self] in
            await compressBlocking(sources: sources, to: dest)
        } completion: { code in
            if code == 0 {
                self.progress = 100  // 7zz 不保证打到 100%，成功后补齐。
                self.currentItem = nil
                var message = String(format: L("压缩完成 → %@"), dest.path)
                if self.options.deleteSourceAfterCompress {
                    let moved = self.moveToTrash(sources: sources, destination: dest)
                    if moved > 0 {
                        message = String(format: L("压缩完成 → %@（%d 个源文件已移到废纸篓）"), dest.path, moved)
                    }
                }
                self.statusText = message
                self.options.resetPassword()
                self.load(archive: dest)
            } else {
                self.statusText = code == 255 ? L("已取消") : L("压缩失败")
                if code != 255 { self.errorMessage = Self.describe(exitCode: code) }
            }
        }
    }

    /// 压缩后删源文件属于不可轻易撤销的操作，即使设置里已经勾选也要再确认一次。
    private func confirmSourceRemovalIfNeeded(sources: [URL]) -> Bool {
        guard options.deleteSourceAfterCompress else { return true }
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

    private func extractBlocking(archive: URL, to dest: URL, items: [String]) async -> Int32 {
        // 已知有加密条目但还没拿到密码：先问，省掉一次必然失败的解压。
        if archiveEncrypted, archivePassword == nil {
            guard let entered = await askPassword(isRetry: false) else { return 255 }
            archivePassword = entered
        }

        var result = await runExtract(archive: archive, to: dest, items: items, password: archivePassword)

        // 兜底：有些归档的加密条目在列目录时看不出（例如加密的 rar），
        // 跑到一半才报错，这时再问一次并重跑。
        if result.code != 0, Self.isPasswordError(result.error) {
            guard let entered = await askPassword(isRetry: archivePassword != nil) else { return 255 }
            archivePassword = entered
            result = await runExtract(archive: archive, to: dest, items: items, password: entered)
        }

        if result.code == 0 {
            await expandIntermediateTar(archive: archive, destination: dest)
        }
        return result.code
    }

    private func runExtract(
        archive: URL,
        to dest: URL,
        items: [String],
        password: String?
    ) async -> (code: Int32, error: String) {
        let runner = self.runner
        var args = ["x", archive.path, "-o\(dest.path)", "-y", "-bsp1", "-bb1", "-p\(password ?? "")"]
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
    private func expandIntermediateTar(archive: URL, destination: URL) async {
        let ext = archive.pathExtension.lowercased()
        guard ["gz", "bz2", "xz", "z", "tgz", "tbz", "tbz2", "txz"].contains(ext) else { return }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        // 只有「恰好解出一个 .tar」才继续，避免误伤同名内容。
        guard contents.count == 1,
              let tar = contents.first,
              tar.pathExtension.lowercased() == "tar" else { return }

        let result = await runSync(["x", tar.path, "-o\(destination.path)", "-y", "-bso0", "-bsp0", "-p"])
        if result.code == 0 {
            // 中间产物是刚才这一步自己解出来的，展开后清掉，不留在用户目录里。
            try? FileManager.default.removeItem(at: tar)
        }
    }

    private func compressBlocking(sources: [URL], to dest: URL) async -> Int32 {
        // gzip / bzip2 / xz 一次只能压一个文件流，目录或多项必须先打 tar。
        if options.format.isSingleStream, sources.count > 1 || sources.contains(where: Self.isDirectory) {
            return await compressViaTar(sources: sources, to: dest)
        }
        return await runCompress(sources: sources, to: dest, progressRange: 0...100)
    }

    private func runCompress(sources: [URL], to dest: URL, progressRange: ClosedRange<Int>) async -> Int32 {
        var args = ["a", dest.path]
        args.append(contentsOf: options.extraArguments())
        args.append(contentsOf: ["-bsp1", "-bb1"])
        args.append(contentsOf: sources.map(\.path))
        return await runWithProgress(args, progressRange: progressRange)
    }

    /// 两步走：先打 tar，再用 gzip/bzip2/xz 压。
    /// 产物是标准的 `.tar.gz` / `.tar.bz2` / `.tar.xz`，解压时由
    /// `expandIntermediateTar` 还原成内容。
    private func compressViaTar(sources: [URL], to dest: URL) async -> Int32 {
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
        if options.excludeMacResources {
            tarArgs.append(contentsOf: CompressionOptions.macResourceExcludes)
        }
        tarArgs.append(contentsOf: ["-bso0", "-bsp0"])
        tarArgs.append(contentsOf: sources.map(\.path))

        let tarCode = await runWithProgress(tarArgs, progressRange: 0...50)
        guard tarCode == 0 else { return tarCode }

        var args = ["a", dest.path, options.format.typeFlag]
        if options.format.supportsLevel {
            args.append("-mx=\(options.level.mx)")
        }
        args.append(contentsOf: ["-bsp1", "-bb1", tarURL.path])
        return await runWithProgress(args, progressRange: 50...100)
    }

    /// 跑一次 7zz 并把百分比映射到 `progressRange` 区间（两步流程用）。
    private func runWithProgress(_ args: [String], progressRange: ClosedRange<Int>) async -> Int32 {
        let runner = self.runner
        let span = Double(progressRange.upperBound - progressRange.lowerBound)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var code: Int32 = -1
                do {
                    let process = try runner.start(
                        arguments: args,
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
                var out = ""
                var err = ""
                let code = (try? runner.run(
                    arguments: args,
                    onLine: { out += $0 + "\n" },
                    onError: { err += $0 + "\n" }
                )) ?? -1
                continuation.resume(returning: (code, out, err))
            }
        }
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
        switch url.host {
        case "extract":
            extractAutomatically(urls)
        case "compress":
            compressAutomatically(urls)
        default:
            break
        }
    }

    // MARK: - Helpers

    /// 密码框：挂起等待用户输入，取消返回 nil。
    @MainActor
    private func askPassword(isRetry: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            passwordContinuation = continuation
            passwordPrompt = PasswordPrompt(
                title: isRetry ? L("密码不正确") : L("需要密码"),
                message: isRetry
                    ? L("这个归档的密码不对，请重新输入。")
                    : L("这个归档已加密，需要密码才能解压。")
            )
        }
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
        let stem = first.deletingPathExtension().lastPathComponent
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
        case 255: return L("已取消")
        default: return String(format: L("未知错误（7-Zip 退出码 %d）"), exitCode)
        }
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
