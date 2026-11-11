import AppKit

/// 在访达里定位任务产物的统一入口。
///
/// `NSWorkspace.activateFileViewerSelecting` 传「目录」时，系统打开的是该目录的
/// **父目录**并把该目录选中。解压平铺到当前目录时若直接把目标目录传进去，
/// 窗口就会停在上一层（在 Downloads 里解压，却打开 qujunxian 家目录并高亮「下载」）。
/// 因此只把「具体产物」交给它；一件产物都没有时改用 `open` 直接打开目标目录内容。
enum FinderReveal {
    static func show(items: [URL], in folder: URL) {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        appDbg("FinderReveal folder=\(folder.path) items=\(existing.map(\.lastPathComponent))")
        if existing.isEmpty {
            // 拿不到产物时才退回「打开目录内容」，绝不 select 目录（会跳到父目录）。
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
}

/// 任务完成后的系统通知。
///
/// 访达右键是「没有窗口」的链路：任务跑完、进程随即退出，用户看不到任何结果，
/// 所以结果必须由通知中心交付（跟 Keka 一致）。
///
/// 为什么用 `NSUserNotificationCenter` 而不是 `UNUserNotificationCenter`：
/// 本机（macOS 26）上 `UNUserNotificationCenter.requestAuthorization` 对
/// 开发签名、未公证的 App 一律直接返回
/// `UNErrorDomain Code=1 "Notifications are not allowed for this application"`，
/// 连授权框都不弹；随后整条 UN 通道都发不出东西。老接口反过来——
/// 第一次 `deliver` 会正常弹出系统的「允许通知」横幅，允许之后就能一直用。
/// 这里因此只用老接口，保证「第一次右键就能拿到授权」。
final class Notifier: NSObject, NSUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// 本次启动是被「点击通知」拉起来的：不能再自动建主窗口。
    private(set) var launchedFromNotification = false

    private var ready = false

    /// 幂等：装上代理。代理必须在 `deliver` 之前设好，否则点击通知收不到回调。
    func prepare() {
        guard !ready else { return }
        ready = true
        NSUserNotificationCenter.default.delegate = self
    }

    func success(title: String, body: String, reveal: URL?) {
        deliver(title: title, body: body, reveal: reveal?.path)
    }

    /// 解压完成：带上本次新增的全部顶层产物，点击通知时选中它们而不是「目标目录」。
    func success(title: String, body: String, revealItems: [URL], in folder: URL) {
        deliver(
            title: title,
            body: body,
            revealItems: revealItems.map(\.path),
            revealFolder: folder.path
        )
    }

    func failure(title: String, body: String) {
        deliver(title: title, body: body)
    }

    private func deliver(
        title: String,
        body: String,
        reveal: String? = nil,
        revealItems: [String]? = nil,
        revealFolder: String? = nil
    ) {
        prepare()
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        var info: [String: Any] = [:]
        if let reveal { info["reveal"] = reveal }
        if let revealItems, !revealItems.isEmpty { info["revealItems"] = revealItems }
        if let revealFolder { info["revealFolder"] = revealFolder }
        if !info.isEmpty { notification.userInfo = info }
        NSUserNotificationCenter.default.deliver(notification)
        appDbg("notifier delivered \(title) | \(body)")
    }

    // MARK: - NSUserNotificationCenterDelegate

    /// App 恰好在前台时也要显示，不然用户什么都看不到。
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        launchedFromNotification = true
        AppDelegate.shared?.suppressAutoWindow()

        if let paths = notification.userInfo?["revealItems"] as? [String], !paths.isEmpty {
            let items = paths.map { URL(fileURLWithPath: $0) }
            let folder = (notification.userInfo?["revealFolder"] as? String)
                .map { URL(fileURLWithPath: $0) }
                ?? items[0].deletingLastPathComponent()
            // 产物可能已被用户移走，FinderReveal 会过滤不存在的，空了就直接打开目标目录。
            FinderReveal.show(items: items, in: folder)
        } else if let path = notification.userInfo?["reveal"] as? String {
            let url = URL(fileURLWithPath: path)
            // 单个目标可能是目录（压缩完成指向新建文件夹）：目录用 open 打开内容，
            // 文件用 select 选中，两者都不会再跳到上一层。
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }

        // 纯通知点击拉起的进程没有给过界面，做完就退，别在后台赖着。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !MainWindowController.shared.isVisible else { return }
            NSApp.terminate(nil)
        }
    }
}
