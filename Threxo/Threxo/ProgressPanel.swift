import SwiftUI
import AppKit
import Combine

// MARK: - 进度弹窗（v1.2）

/// 压缩 / 解压任务的种类。标题、图标、主色都从这里派生，
/// 避免页面链路和访达右键链路各自写一套文案。
enum TaskProgressKind {
    case compress
    case extract

    var title: String {
        switch self {
        case .compress: return L("正在压缩")
        case .extract:  return L("正在解压")
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "doc.zipper"
        case .extract:  return "square.and.arrow.down"
        }
    }
}

/// 任务开始时由各链路给出的静态信息。
///
/// `totalBytes` 为 0 表示还没算出来：递归统计源文件夹可能要几百毫秒，
/// 交给 `sizeProvider` 在后台算完回填，绝不阻塞弹窗出现。
struct TaskProgressDescriptor {
    let kind: TaskProgressKind
    let fileName: String
    var totalBytes: Int64 = 0
    var sizeProvider: (() -> Int64)?
}

/// 一次任务的可观察进度。7zz 只吐百分比，字节数按百分比从总量折算：
/// `已处理 = 总量 × 百分比`，与原型里「314.7 MB / 542.5 MB」的语义一致。
final class TaskProgressState: ObservableObject {
    let kind: TaskProgressKind
    @Published var fileName: String
    @Published var totalBytes: Int64
    @Published var percent: Int
    @Published var currentItem: String?
    @Published var phase: String
    /// 完成（或取消）后置 true：进度条补满，取消按钮不再可点。
    @Published var finished = false

    init(kind: TaskProgressKind, fileName: String, totalBytes: Int64,
         percent: Int = 0, phase: String = "") {
        self.kind = kind
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.percent = percent
        self.phase = phase
    }

    private var fraction: Double {
        Double(min(max(percent, 0), 100)) / 100.0
    }

    /// 已处理字节数（按百分比折算）。
    var processedBytes: Int64 {
        guard totalBytes > 0 else { return 0 }
        return Int64((Double(totalBytes) * fraction).rounded())
    }

    /// 底部「已处理 / 总量」。单位由总量决定，两项始终同单位，
    /// 避免出现「943.2 MB / 1.3 GB」这种混着读的数。
    var byteSummary: String? {
        guard totalBytes > 0 else { return nil }
        let total = Double(totalBytes)
        let unit: Double
        let suffix: String
        if total >= 1_000_000_000 { unit = 1_000_000_000; suffix = "GB" }
        else if total >= 1_000_000 { unit = 1_000_000; suffix = "MB" }
        else if total >= 1_000 { unit = 1_000; suffix = "KB" }
        else { unit = 1; suffix = "B" }
        if unit == 1 {
            return String(format: "%.0f %@ / %.0f %@",
                          Double(processedBytes), suffix, total, suffix)
        }
        return String(format: "%.1f %@ / %.1f %@",
                      Double(processedBytes) / unit, suffix, total / unit, suffix)
    }
}

// MARK: - 弹窗视图

/// 按原型做的圆角浮层卡片：图标 + 标题/文件名 + 取消，中间进度条与百分比，
/// 底部「已处理 / 总量」。所有颜色走 `AppTheme`，后续换主题自动跟随。
struct TaskProgressView: View {
    @ObservedObject var state: TaskProgressState
    @ObservedObject private var themeStore = ThemeStore.shared
    let onCancel: () -> Void

    /// 卡片本身尺寸；窗口会多留一圈给阴影，避免系统阴影画出直角。
    static let cardWidth: CGFloat = 720
    static let cardHeight: CGFloat = 268

    private var theme: AppTheme { themeStore.theme }

    var body: some View {
        card
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .shadow(color: Color.black.opacity(0.16), radius: 22, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.kind.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(state.fileName)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                cancelButton
            }

            Spacer(minLength: 14)

            HStack(spacing: 18) {
                progressBar
                    .frame(height: 18)
                Text("\(min(max(state.percent, 0), 100))%")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }

            Spacer(minLength: 12)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let summary = state.byteSummary {
                    Text(summary)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                } else {
                    Text(state.phase)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let item = state.currentItem, !item.isEmpty {
                    Text(item)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// 左上角图标：浅灰圆角底座 + 粉紫渐变的 SF Symbol，对应原型里的火箭图标。
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                )
            Image(systemName: state.kind.symbol)
                .font(.system(size: 27, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.96, green: 0.36, blue: 0.56), theme.primaryEnd],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: 58, height: 58)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            HStack(spacing: 7) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                Text(L("取消"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Capsule().fill(theme.danger))
        }
        .buttonStyle(.plain)
        .disabled(state.finished)
        .opacity(state.finished ? 0.45 : 1)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.primaryStart.opacity(0.14))
                Capsule()
                    .fill(theme.primaryStart)
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(state.percent, 0), 100)) / 100))
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.percent)
    }
}

// MARK: - 浮层窗口

/// 全局唯一的无边框浮层。页面内任务和访达右键的无窗口任务共用同一套视图，
/// 这样进度展示不再分「窗口里有 / 只有菜单栏」两种形态。
final class TaskProgressPanel: NSObject {
    static let shared = TaskProgressPanel()

    private var window: NSWindow?
    private var hosting: NSHostingView<TaskProgressView>?
    /// 四周留出阴影余量，透明窗口本身不画系统阴影。
    private static let shadowInset: CGFloat = 28

    var isVisible: Bool { window?.isVisible ?? false }

    private var contentSize: NSSize {
        NSSize(width: TaskProgressView.cardWidth + Self.shadowInset * 2,
               height: TaskProgressView.cardHeight + Self.shadowInset * 2)
    }

    func show(_ state: TaskProgressState) {
        let root = TaskProgressView(state: state) {
            AppModel.shared.cancelProgressTask()
        }
        if let hosting {
            hosting.rootView = root
        } else {
            makeWindow(with: root)
        }
        positionWindow()
        guard let window else { return }
        // 透明的无边框窗口做 alpha 淡入时，非激活状态下动画可能停在半透明，
        // 整张卡片连同文字、进度条都会发灰。直接满不透明，只在收起时淡出。
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    /// 任务结束后的收起。不用 alpha 动画：连续两个任务紧挨着时，
    /// 上一次的淡出会把新弹窗的 alpha 又拉回 0，表现成「第二个任务没有弹窗」。
    func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        window.alphaValue = 1
    }

    private func makeWindow(with root: TaskProgressView) {
        let size = contentSize
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.ignoresMouseEvents = false
        self.window = window
        self.hosting = hosting
    }

    /// 主窗口开着就压在主窗口中央偏上；纯静默任务（访达右键 / 双击快速解压）
    /// 没有主窗口，直接居中到当前屏幕。
    private func positionWindow() {
        guard let window else { return }
        let size = window.frame.size
        let anchor: NSRect
        if let main = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && $0.frame.width > 600 && $0.styleMask.contains(.titled)
        }) {
            anchor = main.frame
        } else {
            anchor = NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
        // 主窗口可能被拖到屏幕边缘（或停在副屏），只按它的中心摆会把浮层推出可视区。
        // 取锚点所在屏幕的可见区域做一次钳制，保证整张卡片都在屏幕内。
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? anchor
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 12),
                   screen.maxX - size.width - 12)
        let y = min(max(anchor.midY - size.height / 2 + 32, screen.minY + 24),
                   screen.maxY - size.height - 24)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
