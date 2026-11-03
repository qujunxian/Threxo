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

/// 主窗口刻意不写成 SwiftUI 的 `WindowGroup`：`WindowGroup` 在 App 启动时
/// 必然建窗，而访达右键走的是**静默任务**——不该为了解一个压缩包把主界面弹出来。
/// 改成「零窗口启动 + 按需创建 NSWindow」之后：
///   · 右键解压/压缩全程不建窗、不抢焦点、不在 Dock 里留图标；
///   · 双击归档、点 Dock 图标、菜单命令需要界面时才建窗。
@main struct ThrexoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        // Finder 扩展必须由容器 App 设置监视目录，pkd 才会真正激活扩展。
        // 设在扩展的 init 里不保证持久化，这里做权威设置（MVP 监视整个磁盘）。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    var body: some Scene {
        // 只声明设置面板：`Settings` 启动时不建窗，正好当「零窗口」应用的壳。
        Settings { SettingsPane() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("打开归档…") {
                        MainWindowController.shared.show()
                        model.openArchive()
                    }
                    .keyboardShortcut("o")

                    Button("压缩…") {
                        MainWindowController.shared.show()
                        model.compress()
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        appDbg("willFinishLaunching")
        installURLEventHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDbg("didFinishLaunching")
        // SwiftUI 自身也会注册 URL 事件处理器，这里再装一次确保是我们接。
        installURLEventHandler()
        // 通知必须在「启动完成」之后再申请授权：更早访问 UNUserNotificationCenter
        // 会拿到异常状态（实测直接判成 denied，之后再也弹不出授权框）。
        Notifier.shared.prepare()

        // 只有「用户直接打开 App」才需要窗口。访达右键唤起时，URL 事件要等
        // LaunchServices 把 App 拉起来之后才投递，实测冷启动可以晚到 0.5s 以上；
        // 等待窗口太短就会出现「静默任务先建了个空窗、随后才被收回」的闪烁。
        // 1.5s 是实测的上界，用户直接双击时这段时间由 Dock 图标的弹跳覆盖。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard !self.jobStarted, !Notifier.shared.launchedFromNotification else { return }
            MainWindowController.shared.show(auto: true)
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

    // MARK: 文件打开

    /// 双击归档 / 拖到 Dock 图标 / Finder「打开方式」——这些是用户主动要界面。
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
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

    /// 进入静默模式：不建窗、不抢焦点；进度只在菜单栏显示。
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
            guard !MainWindowController.shared.hasShown else { return }
            appDbg("terminate after headless job")
            NSApp.terminate(nil)
        }
    }
}

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

        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(cancel)
        item.menu = menu
    }

    @objc private func cancelJob() {
        model?.cancel()
    }
}

// MARK: - 设置面板

/// App 里唯一的 Scene。压缩选项在主窗口工具栏里，这里只放说明与版本信息。
private struct SettingsPane: View {
    @ObservedObject private var options = CompressionOptions.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("千梭"))
                        .font(.title3.bold())
                    Text(String(format: L("版本 %@ · 7-Zip 引擎"), version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("访达右键"))
                    .font(.callout.weight(.semibold))
                Text(L("右键压缩包直接解压到压缩包所在的文件夹；右键文件或文件夹直接在当前目录生成压缩包。两种情况都不会打开主窗口。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("压缩设置"))
                    .font(.callout.weight(.semibold))
                Text(String(format: L("格式、级别与密码在主窗口工具栏的滑块按钮里调整，当前格式为 %@。"), options.format.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 420, height: 280, alignment: .topLeading)
    }
}
