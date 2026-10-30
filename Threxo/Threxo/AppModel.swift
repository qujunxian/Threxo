import Foundation
import AppKit
import Combine
import FinderSync
import UniformTypeIdentifiers

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
    @Published var statusText = "就绪"
    @Published var errorMessage: String?
    /// 当前正在处理的文件（来自 7zz -bb1 的进度行）。
    @Published var currentItem: String?

    /// 访达右键扩展是否已在「系统设置 → 登录项与扩展」里启用。
    /// 由 pkd 提供，状态可能滞后数秒，界面上提供手动刷新。
    @Published var finderExtensionEnabled = false

    private var activeProcess: Process?
    private let runner: SevenZipRunner

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
        panel.message = "选择要打开的归档文件"
        panel.prompt = "打开"
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
        statusText = "正在读取归档…"

        let runner = self.runner
        Task.detached(priority: .userInitiated) {
            var out = ""
            var err = ""
            let code = (try? runner.run(
                arguments: ["l", "-slt", "-ba", url.path],
                onLine: { out += $0 + "\n" },
                onError: { err += $0 + "\n" }
            )) ?? -1

            let parsed = code == 0 ? ArchiveLister.parse(out) : []
            let tree = ArchiveTree.build(parsed)
            await MainActor.run {
                self.isBusy = false
                if code == 0 {
                    self.entries = parsed
                    self.treeNodes = tree
                    let files = parsed.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
                    self.statusText = "已加载 \(url.lastPathComponent) · \(files) 个文件"
                } else {
                    self.errorMessage = "读取归档失败：\(Self.describe(exitCode: code))"
                    self.statusText = "读取失败"
                    if !err.isEmpty { self.currentItem = nil }
                }
            }
        }
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
        extract(archive: archive, to: dest, items: [], status: "正在解压…", reveal: true)
    }

    /// 手动选择解压位置。
    func extractAllChoosingDestination() {
        guard !isBusy, let archive = archiveURL else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择解压目标文件夹"
        panel.prompt = "解压到此处"
        panel.directoryURL = archive.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        extract(archive: archive, to: dest, items: [], status: "正在解压…", reveal: true)
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
            status: "正在解压所选的 \(items.count) 个文件…",
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
                self.statusText = "解压完成 → \(dest.path)"
                if reveal {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } else {
                self.statusText = code == 255 ? "已取消" : "解压失败"
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
        runTask(status: "正在解压…") { [self] in
            var lastCode: Int32 = 0
            for (index, archive) in archives.enumerated() {
                await MainActor.run {
                    self.statusText = archives.count > 1
                        ? "正在解压 (\(index + 1)/\(archives.count))…"
                        : "正在解压…"
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
                    ? "已完成 \(archives.count) 个归档的解压"
                    : "解压完成"
            } else {
                self.statusText = code == 255 ? "已取消" : "解压失败"
                if code != 255 { self.errorMessage = Self.describe(exitCode: code) }
            }
        }
    }

    // MARK: - Compress (UI flow)

    func compress() {
        guard !isBusy else { return }

        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.message = "选择要压缩的文件或文件夹"
        open.prompt = "下一步"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let sources = open.urls

        let save = NSSavePanel()
        save.nameFieldStringValue = "归档.zip"
        save.message = "选择 ZIP 保存位置"
        save.prompt = "压缩"
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let dest = save.url else { return }

        compress(sources: sources, to: dest)
    }

    /// FinderSync flow: zip the given items next to the first one.
    /// 不覆盖已有归档：同名时自动追加序号（a.zip → a 2.zip），避免静默丢数据。
    func compressAutomatically(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        let dir = urls[0].deletingLastPathComponent()
        let stem = urls[0].deletingPathExtension().lastPathComponent
        let base = stem.isEmpty ? "Archive" : stem

        var dest = dir.appendingPathComponent("\(base).zip")
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(counter).zip")
            counter += 1
        }
        compress(sources: urls, to: dest)
    }

    private func compress(sources: [URL], to dest: URL) {
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        runTask(status: "正在压缩…") { [self] in
            await compressBlocking(sources: sources, to: dest)
        } completion: { code in
            if code == 0 {
                self.progress = 100  // 7zz 不保证打到 100%，成功后补齐。
                self.currentItem = nil
                self.statusText = "压缩完成 → \(dest.path)"
                self.load(archive: dest)
            } else {
                self.statusText = code == 255 ? "已取消" : "压缩失败"
                if code != 255 { self.errorMessage = Self.describe(exitCode: code) }
            }
        }
    }

    // MARK: - Blocking 7zz operations (run off the main thread)

    private func extractBlocking(archive: URL, to dest: URL, items: [String]) async -> Int32 {
        let runner = self.runner
        var args = ["x", archive.path, "-o\(dest.path)", "-y", "-bsp1", "-bb1"]
        args.append(contentsOf: items)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var code: Int32 = -1
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
                        onError: { _ in }
                    )
                    DispatchQueue.main.async { self.activeProcess = process }
                    process.waitUntilExit()
                    code = process.terminationStatus
                } catch {
                    DispatchQueue.main.async { self.errorMessage = "\(error)" }
                }
                continuation.resume(returning: code)
            }
        }
    }

    private func compressBlocking(sources: [URL], to dest: URL) async -> Int32 {
        let runner = self.runner
        let args = ["a", dest.path, "-tzip", "-mx=5", "-bsp1", "-bb1"]
            + sources.map(\.path)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var code: Int32 = -1
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
                        onError: { _ in }
                    )
                    DispatchQueue.main.async { self.activeProcess = process }
                    process.waitUntilExit()
                    code = process.terminationStatus
                } catch {
                    DispatchQueue.main.async { self.errorMessage = "\(error)" }
                }
                continuation.resume(returning: code)
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
        return name.isEmpty ? "解压结果" : name
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
        "xz", "txz", "zst", "lz", "lzma", "cab", "iso", "jar", "war",
    ]

    /// 把 7-Zip 的退出码翻译成人话，替代裸露的 "退出码 2"。
    static func describe(exitCode: Int32) -> String {
        switch exitCode {
        case 0: return "完成"
        case 1: return "完成，但有部分文件被跳过（可能被占用、无权限或路径过长）"
        case 2: return "归档损坏、密码错误，或目标磁盘写入失败"
        case 7: return "命令参数错误"
        case 8: return "内存不足，请关闭其他应用后重试"
        case 255: return "已取消"
        default: return "未知错误（7-Zip 退出码 \(exitCode)）"
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
