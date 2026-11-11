import SwiftUI
import AppKit
import Combine
import FinderSync

// MARK: - 调试日志

/// 仅 Debug 构建生效，写入 `/tmp/threxo-app.log`。
/// Release 下为 no-op，参数也不会被求值。
func appDbg(_ message: @autoclosure () -> String) {
    #if DEBUG
    let line = "[\(Date().timeIntervalSince1970)] \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/threxo-app.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

// MARK: - 应用入口

extension Notification.Name {
    /// 菜单「查找 ⌘F」→ 主窗口搜索框聚焦。
    static let threxoFocusSearch = Notification.Name("threxo.focusSearch")
}

/// 主窗口刻意不写成 SwiftUI 的 `WindowGroup`：`WindowGroup` 在 App 启动时
/// 必然建窗，而访达右键走的是**静默任务**——不该为了解一个压缩包把主界面弹出来。
/// 改成「零窗口启动 + 按需创建 NSWindow」之后：
///   · 右键解压/压缩不建主窗口，只弹一枚进度浮层，任务结束自动收起；
///   · 双击归档、点 Dock 图标、菜单命令需要界面时才建窗。
@main struct ThrexoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        // Finder 扩展必须由容器 App 设置监视目录，pkd 才会真正激活扩展。
        // 设在扩展的 init 里不保证持久化，这里做权威设置（整个磁盘 + 外接卷挂载点）。
        SettingsStore.applyFinderDirectories(SettingsStore.shared.finderMenuOnExternalVolumes)
    }

    var body: some Scene {
        // `Settings` 只为满足「App 必须声明至少一个 Scene」，内容留空。
        // 真正的设置窗口由 `SettingsWindowController` 按需创建，尺寸和侧边栏才由我们说了算。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L("设置…")) {
                        SettingsWindowController.shared.show()
                    }
                    .keyboardShortcut(",")
                }

                CommandGroup(replacing: .appInfo) {
                    Button(L("关于千梭")) {
                        AboutWindowController.shared.show()
                    }
                }

                CommandGroup(replacing: .newItem) {
                    Button("打开归档…") {
                        MainWindowController.shared.show()
                        model.openArchive()
                    }
                    .keyboardShortcut("o")

                    Button("压缩…") {
                        MainWindowController.shared.show()
                        ComposeArchiveState.shared.activate()
                    }
                    .keyboardShortcut("n")

                    Divider()

                    Button("解压") {
                        MainWindowController.shared.show()
                        model.extractAll()
                    }
                    .keyboardShortcut("e")
                    .disabled(model.isBusy || model.entries.isEmpty || model.hasSelection)

                    Button(String(format: L("解压所选 %d 项"), model.selection.count)) {
                        MainWindowController.shared.show()
                        model.extractSelected()
                    }
                    .keyboardShortcut("e")
                    .disabled(model.isBusy || !model.hasSelection)

                    Button("解压到…") {
                        MainWindowController.shared.show()
                        model.extractAllChoosingDestination()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.entries.isEmpty)

                    Divider()

                    Button("重命名…") {
                        if let path = model.selection.first { model.renameEntry(path) }
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.selection.count != 1 || !model.canEditCurrentArchive)

                    Button("从归档中删除") { model.deleteEntries(Array(model.selection)) }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(!model.hasSelection || !model.canEditCurrentArchive)

                    Divider()

                    Button("查找") {
                        MainWindowController.shared.show()
                        // 搜索框在 ContentView 里，用通知让它把自己切成第一响应者，
                        // 免得为了一个快捷键把 BrowserState 提升成全局单例。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            NotificationCenter.default.post(name: .threxoFocusSearch, object: nil)
                        }
                    }
                    .keyboardShortcut("f")
                    .disabled(model.archiveURL == nil)
                }

                // 嵌套压缩包：⌘↑ 退回外层，和访达的「上层文件夹」一个语义。
                CommandGroup(after: .newItem) {
                    Divider()
                    Button(L("返回外层压缩包")) {
                        model.closeNestedArchive()
                    }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.isNestedArchive)
                }
            }
    }
}

// MARK: - AppDelegate

/// 系统级入口：URL Scheme（访达右键）、文件打开、Dock 图标点击。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// SwiftUI 的 `@NSApplicationDelegateAdaptor` 会自己持有一份实例，
    /// `NSApp.delegate` 未必能稳定取到，所以在这里留一个明确入口。
    private(set) static var shared: AppDelegate?

    /// 本次启动是否有静默任务接手。用来判断「还要不要在主窗口里给用户看东西」。
    private var jobStarted = false
    private var headlessJobs = 0
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        appDbg("willFinishLaunching")
        installURLEventHandler()
        installOpenDocumentsHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDbg("didFinishLaunching")
        // SwiftUI 自身也会注册 URL 事件处理器，这里再装一次确保是我们接。
        installURLEventHandler()
        // 通知必须在「启动完成」之后再申请授权：更早访问 UNUserNotificationCenter
        // 会拿到异常状态（实测直接判成 denied，之后再也弹不出授权框）。
        Notifier.shared.prepare()

        // 外观设置在建第一个窗口之前落地，避免先出浅色再跳深色的闪动。
        SettingsStore.shared.applyAppearance()

        // 底栏写了「空格」「⏎」，就真的让它们能用：预览 / 全部解压。
        installQuickKeys()

        #if DEBUG
        // 仅调试：把压缩向导离屏渲染成 PNG 后退出，便于无界面环境下核对布局。
        if let path = ProcessInfo.processInfo.environment["THREXO_RENDER_WIZARD"] {
            renderWizardPreview(to: path)
            NSApp.terminate(nil)
            return
        }

        // 仅调试：把统一进度弹窗离屏渲染成 PNG，核对压缩 / 解压两种文案与深浅色。
        if let out = ProcessInfo.processInfo.environment["THREXO_RENDER_PROGRESS"] {
            renderProgressPreview(to: out)
            NSApp.terminate(nil)
            return
        }

        // 仅调试：核对「处理器使用」卡片的本机核心数文案与默认档。
        if let out = ProcessInfo.processInfo.environment["THREXO_RENDER_CORES"] {
            renderCoresPreview(to: out)
            NSApp.terminate(nil)
            return
        }

        // 仅调试：打开一个归档，把主窗口（含列表 / 图标 / 分栏 / 详情）快照成 PNG。
        // 锁屏环境下 screencapture 只能拍到锁屏界面，这条路是唯一能看到真实控件布局的方式。
        if let out = ProcessInfo.processInfo.environment["THREXO_RENDER_BROWSER"] {
            let env = ProcessInfo.processInfo.environment
            let archive = env["THREXO_RENDER_ARCHIVE"].map { URL(fileURLWithPath: $0) }
            let mode = env["THREXO_RENDER_MODE"].flatMap(SettingsStore.BrowseMode.init(rawValue:))
            renderBrowserPreview(archive: archive, mode: mode, to: out)
            NSApp.terminate(nil)
            return
        }
        #endif

        // 只有「用户直接打开 App」才需要窗口。访达右键唤起时，URL 事件要等
        // LaunchServices 把 App 拉起来之后才投递，实测冷启动可以晚到 0.5s 以上；
        // 等待窗口太短就会出现「静默任务先建了个空窗、随后才被收回」的闪烁。
        // 1.5s 是实测的上界，用户直接双击时这段时间由 Dock 图标的弹跳覆盖。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard !self.jobStarted, !Notifier.shared.launchedFromNotification else { return }
            // 首次启动先走设置向导；静默任务（右键 / URL 事件）不受影响，
            // 因为它们在上面已经被 jobStarted 挡掉了。
            if !OnboardingWindowController.isCompleted {
                OnboardingWindowController.shared.show()
            } else {
                MainWindowController.shared.show(auto: true)
            }
        }
    }

    private func installURLEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// 接管「用千梭打开」和双击归档。
    ///
    /// 只实现 `application(_:openFiles:)` 不够：App 的 Scene 里没有 WindowGroup，
    /// SwiftUI 的 delegate adaptor 不会把 odoc 事件转下来（实测连方法都不进），
    /// 表现就是双击归档毫无反应。这里跟 URL 事件一样自己注册处理器。
    private func installOpenDocumentsHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc private func handleOpenDocumentsEvent(
        _ event: NSAppleEventDescriptor,
        withReply reply: NSAppleEventDescriptor
    ) {
        guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }

        var urls: [URL] = []
        let count = list.numberOfItems
        if count > 0 {
            for index in 1...count {
                if let url = Self.url(from: list.atIndex(index)) {
                    urls.append(url)
                }
            }
        } else if let url = Self.url(from: list) {
            urls.append(url)
        }
        appDbg("openDocuments count=\(urls.count)")

        guard !urls.isEmpty else { return }

        // 设置里勾了「双击时快速解压」：不进主窗口，直接按右键那套静默链路解到同级目录。
        if SettingsStore.shared.quickExtractOnDoubleClick,
           let archive = urls.first(where: { AppModel.isArchiveURL($0) }) {
            jobStarted = true
            MainWindowController.shared.retractIfEmpty()
            DispatchQueue.main.async {
                AppModel.shared.extractAutomatically([archive], revealResult: true)
            }
            return
        }

        jobStarted = true
        MainWindowController.shared.retractIfEmpty()
        showMainWindow()
        DispatchQueue.main.async {
            AppModel.shared.receiveOpenFiles(urls)
        }
    }

    /// odoc 里的文件描述符给的是 `file:///…` 形式的 URL 字符串，不是 POSIX 路径。
    /// 直接当成路径会拼出 `/file:///…` 这种不存在的名字（实测读到 errno=2）。
    private static func url(from descriptor: NSAppleEventDescriptor?) -> URL? {
        guard let value = descriptor?.stringValue, !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("file:"), let url = URL(string: value), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: value)
    }

    private func showMainWindow() {
        MainWindowController.shared.show()
    }

    /// 外部原因（点击通知）把 App 拉起来时调用：不要自动建窗，只做它该做的事。
    func suppressAutoWindow() {
        jobStarted = true
        MainWindowController.shared.retractIfEmpty()
    }

    // MARK: URL Scheme（threxo://extract|compress?path=…）

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        appDbg("getURL event")
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: raw) else { return }
        appDbg("getURL url=\(raw)")

        jobStarted = true
        // 万一主窗口已经被启动流程建出来，收回去——右键任务不该弹窗。
        MainWindowController.shared.retractIfEmpty()
        DispatchQueue.main.async {
            AppModel.shared.handleIncomingURL(url)
        }
    }

    // MARK: 快捷键

    /// 只在主窗口里、且焦点不在文本输入时生效。
    /// 用本地监听而不是 `keyboardShortcut`：后者会抢走搜索框里的空格和回车。
    private func installQuickKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = MainWindowController.shared.shortcutWindow,
                  window.isKeyWindow, window.attachedSheet == nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.isEmpty else { return event }
            // 正在输入文字：空格是空格，回车是回车。
            if let responder = window.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            let model = AppModel.shared
            switch event.keyCode {
            case 49:    // 空格
                guard model.canPreviewSelection else { return event }
                model.previewCurrent()
                return nil
            case 36, 76: // 回车 / 小键盘回车
                guard !ComposeArchiveState.shared.isActive,
                      model.archiveURL != nil, !model.entries.isEmpty,
                      !model.isBusy else { return event }
                model.extractAll()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: 文件打开

    /// 双击归档 / 拖到 Dock 图标 / Finder「打开方式」——这些是用户主动要界面。
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if SettingsStore.shared.quickExtractOnDoubleClick,
           let archive = urls.first(where: { AppModel.isArchiveURL($0) }) {
            DispatchQueue.main.async {
                AppModel.shared.extractAutomatically([archive], revealResult: true)
            }
            sender.reply(toOpenOrPrint: .success)
            return
        }
        showMainWindow()
        DispatchQueue.main.async {
            AppModel.shared.receiveOpenFiles(urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    /// 点 Dock 图标、在 Finder 里再次打开已运行的 App。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: 静默任务生命周期

    /// 进入静默模式：不建主窗口、不抢焦点；进度走统一浮层，菜单栏保留兜底入口。
    /// - Returns: 是否真的按静默方式跑（主窗口已可见时返回 false，任务进度就显示在窗口里）。
    ///
    /// 刻意**不**切 `activationPolicy(.accessory)`：切成后台程序之后系统既不会弹
    /// 「允许通知」的授权横幅，也会把完成通知静默丢弃（实测横幅完全不出现）。
    /// 代价只是任务那几秒内 Dock 里有个图标，比"做完没任何反馈"划算得多。
    @discardableResult
    func beginHeadlessJob() -> Bool {
        guard !MainWindowController.shared.isVisible else { return false }
        headlessJobs += 1
        appDbg("beginHeadlessJob hasShown=\(MainWindowController.shared.hasShown)")
        JobHUD.shared.show(for: AppModel.shared)
        return true
    }

    /// 静默任务收尾。纯静默启动的（从没给过界面）直接退出，不在后台留进程。
    func endHeadlessJob() {
        headlessJobs = max(0, headlessJobs - 1)
        guard headlessJobs == 0 else { return }

        appDbg("endHeadlessJob")
        JobHUD.shared.hide(after: 1.2)
        // 收尾要等两件事：菜单栏进度消失、结果通知送达通知中心。
        // 通知是异步提交给 usernoted 的，进程退得太快会把还没有窗口的横幅一起带走。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.headlessJobs == 0 else { return }
            guard !MainWindowController.shared.isVisible else { return }
            guard !AboutWindowController.shared.isVisible else { return }
            guard !SettingsWindowController.shared.isVisible else { return }
            // 向导窗口开着时不能退出，否则一次右键任务会把设置流程整个关掉。
            guard !OnboardingWindowController.shared.isVisible else { return }
            guard !MainWindowController.shared.hasShown else { return }
            appDbg("terminate after headless job")
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 离屏快照（仅调试）

#if DEBUG
/// 把 SwiftUI 视图挂到一个离屏窗口里，再把它画进位图。
/// `ImageRenderer` 不渲染 `List` / `ScrollView` 的内容，只能走 AppKit 的 `cacheDisplay`。
@MainActor
func snapshotView<V: View>(_ view: V, size: CGSize, to path: String) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()

    hosting.layoutSubtreeIfNeeded()
    // 给 NSTableView 一点时间装载行、异步解压缩略图。
    let deadline = Date().addingTimeInterval(1.2)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    window.orderOut(nil)
}

@MainActor
func renderProgressPreview(to path: String) {
    let env = ProcessInfo.processInfo.environment
    let kind: TaskProgressKind = env["THREXO_PROGRESS_KIND"] == "extract" ? .extract : .compress
    let percent = Int(env["THREXO_PROGRESS_PERCENT"] ?? "") ?? 58
    let total = Int64(env["THREXO_PROGRESS_TOTAL"] ?? "") ?? 568_720_000
    let name = env["THREXO_PROGRESS_NAME"] ?? "SP-AMR-CUSTOM_V08-beta1.zip"
    let state = TaskProgressState(kind: kind, fileName: name,
                                  totalBytes: total, percent: percent,
                                  phase: kind.title)
    let view = TaskProgressView(state: state, onCancel: {})
        .background(Color(nsColor: .windowBackgroundColor))
    let size = CGSize(width: TaskProgressView.cardWidth + 56,
                      height: TaskProgressView.cardHeight + 56)
    snapshotView(view, size: size, to: path)
}

@MainActor
func renderBrowserPreview(archive: URL?, mode: SettingsStore.BrowseMode?, to path: String) {
    let model = AppModel.shared
    let env = ProcessInfo.processInfo.environment
    // 尺寸可指定，用来离屏核对「窗口缩小后会不会遮挡」这类布局问题。
    let width = CGFloat(Double(env["THREXO_RENDER_WIDTH"] ?? "") ?? 1060)
    let height = CGFloat(Double(env["THREXO_RENDER_HEIGHT"] ?? "") ?? 660)
    let size = CGSize(width: width, height: height)

    if env["THREXO_RENDER_COMPOSE"] == "1" {
        var sources: [URL] = []
        for name in ["界面截图-长名字测试版本.png", "原型参考.png", "素材夹"] {
            let url = URL(fileURLWithPath: "/tmp/compose-test/" + name)
            if FileManager.default.fileExists(atPath: url.path) { sources.append(url) }
        }
        ComposeArchiveState.shared.activate(sources: sources)
    } else {
        if let archive { model.debugLoadAndWait(archive) }
        if let mode { SettingsStore.shared.browseMode = mode }
        if let query = env["THREXO_RENDER_SEARCH"] { model.searchText = query }
        if let raw = env["THREXO_RENDER_SORT"], let key = ArchiveSortKey(rawValue: raw) { model.sortKey = key }
        if let selected = env["THREXO_RENDER_SELECT"] { model.selection = [selected] }
    }

    let view = ContentView()
        .environmentObject(model)
        // 离屏窗口是 borderless，不给一层窗口底色会拍出「白底 + 深色列表」的假象。
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: size.width, height: size.height)
    snapshotView(view, size: size, to: path)
}
#endif

// MARK: - 主窗口
/// 按需创建的单窗口控制器。窗口只在这里出现，`App` 的 Scene 里没有窗口。
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?

    /// 是否给过用户界面（决定静默任务结束后要不要退出进程）。
    private(set) var hasShown = false

    /// 这个窗口是不是「启动流程顺手建出来的」。
    /// 只有这种窗口才允许被静默任务收回去；用户自己打开的窗口一律不动。
    private var autoShownAtLaunch = false

    var isVisible: Bool { window?.isVisible ?? false }

    /// 快捷键判定用：只有主窗口是 key window 时才响应空格 / 回车，
    /// 免得在系统弹窗、设置页里误触发。
    var shortcutWindow: NSWindow? { window }

    func show(auto: Bool = false) {
        appDbg("MainWindow.show auto=\(auto)")
        if window == nil { window = makeWindow() }
        hasShown = true
        autoShownAtLaunch = auto
        if auto {
            // 启动后几秒内还没等到 URL 事件，就当作用户正常打开的窗口，不再回收。
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.autoShownAtLaunch = false
            }
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 静默任务抢在窗口之前到达时，把启动流程顺手建出来的空窗口收回去。
    /// 用户自己打开过的窗口不动——他只是顺手在访达里右键一下，不该把窗口弄没。
    func retractIfEmpty() {
        guard autoShownAtLaunch, let window, window.isVisible else { return }
        guard AppModel.shared.archiveURL == nil, !AppModel.shared.isBusy else { return }
        autoShownAtLaunch = false
        window.orderOut(nil)
        // 这个窗口没真正给用户看过，撤回后仍按「纯静默启动」处理，任务跑完就退出。
        hasShown = false
    }

    /// 解压设置里勾了「关闭压缩包窗口」时用。
    func close() {
        window?.close()
    }

    /// 点红绿灯关掉主窗口：把当前归档 / 创建清单清掉。
    /// 窗口对象本身不释放（`isReleasedWhenClosed = false`），下次点 Dock 图标
    /// 复用同一个窗口，但内容已经是欢迎页，不会再莫名其妙回到上一次的压缩包。
    func windowWillClose(_ notification: Notification) {
        autoShownAtLaunch = false
        AppModel.shared.returnToHome()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: ContentView().environmentObject(AppModel.shared))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("千梭")
        window.contentView = hosting
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ThrexoMainWindow")
        if !window.setFrameUsingName("ThrexoMainWindow") {
            window.center()
        }
        return window
    }
}

// MARK: - 菜单栏进度

/// 静默任务期间在菜单栏显示进度，随时可以取消。
/// 主窗口不出现时，这是用户唯一能看到「它在干活」的地方。
final class JobHUD: NSObject {
    static let shared = JobHUD()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hideWork: DispatchWorkItem?
    private weak var model: AppModel?

    func show(for model: AppModel) {
        hideWork?.cancel()
        self.model = model

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: L("千梭"))
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        item.isVisible = true

        cancellables.removeAll()
        model.objectWillChange
            .sink { [weak self] _ in
                // objectWillChange 在改动之前发出，挪到下一拍再读，拿到的才是新值。
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)

        render()
    }

    func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.statusItem?.isVisible = false
            self?.cancellables.removeAll()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func render() {
        guard let model, let item = statusItem else { return }

        item.button?.title = model.isBusy ? " \(model.progress)%" : " ✓"

        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false

        let cancel = NSMenuItem(title: L("取消"), action: #selector(cancelJob), keyEquivalent: "")
        cancel.target = self
        cancel.isEnabled = model.isBusy

        // 任务真的卡住时（没有进程在跑、也没在等密码），给一个不用重启就能恢复的出口。
        let reset = NSMenuItem(title: L("复位卡住的任务"), action: #selector(resetStalled), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = model.canResetStalledTask

        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(cancel)
        menu.addItem(reset)
        item.menu = menu
    }

    @objc private func cancelJob() {
        model?.cancel()
    }

    @objc private func resetStalled() {
        model?.recoverIfStalled(force: true)
    }
}
