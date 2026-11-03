import AppKit

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

    func failure(title: String, body: String) {
        deliver(title: title, body: body, reveal: nil)
    }

    private func deliver(title: String, body: String, reveal: String?) {
        prepare()
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        if let reveal {
            notification.userInfo = ["reveal": reveal]
        }
        NSUserNotificationCenter.default.deliver(notification)
        appDbg("notifier delivered \(title)")
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

        if let path = notification.userInfo?["reveal"] as? String {
            let url = URL(fileURLWithPath: path)
            // 产物可能已被用户移走，只在还存在时定位，避免弹一个空窗口。
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        // 纯通知点击拉起的进程没有给过界面，做完就退，别在后台赖着。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard !MainWindowController.shared.isVisible else { return }
            NSApp.terminate(nil)
        }
    }
}
