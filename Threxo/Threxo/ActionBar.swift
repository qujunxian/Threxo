import SwiftUI
import AppKit
import QuickLookUI

// MARK: - 底部操作条

/// 解压页与创建页共用的底栏外壳：左边一组动作，右边主操作。
///
/// 壳自己负责三件事：统一高度 / 内边距、按可用宽度决定「完整」还是「紧凑」，
/// 以及把紧凑标志通过 Environment 传给里面的按钮和状态文字。
/// 具体放哪些动作由各页面自己决定，但样式一律取自 `AppTheme`。
struct ActionBar<Leading: View, Trailing: View>: View {
    @Environment(\.appTheme) private var theme

    private let leading: () -> Leading
    private let trailing: () -> Trailing

    init(@ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < theme.compactBreakpoint
            HStack(spacing: 10) {
                leading()
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(\.actionBarCompact, compact)
        }
        // GeometryReader 没有固有高度，不给一个就会把底栏压成 0。
        // 高度跟主操作按钮联动，主题换大号按钮时这里自动跟着长。
        .frame(height: theme.primaryHeight + 16)
    }
}

/// 窄屏时自动隐藏的非关键内容（状态文字、计数、错误提示）。
/// 这样按钮永远拿得到宽度，不会再出现文字压到按钮上的遮挡。
struct CompactHidden<Content: View>: View {
    @Environment(\.actionBarCompact) private var compact
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if compact { EmptyView() } else { content() }
    }
}

/// 底栏里的浅色胶囊容器：把几个动作拢成一组。
struct ActionPill<Content: View>: View {
    @Environment(\.appTheme) private var theme
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.pillBackground))
        .overlay(Capsule().strokeBorder(theme.pillBorder))
    }
}

/// 底栏里的单个动作：图标 + 文字 + 可选快捷键小方块。
/// 紧凑模式只留图标，help 仍然保留完整说明。
struct ActionButton: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.actionBarCompact) private var compact

    let title: String
    let symbol: String
    var shortcut: String?
    var isEnabled: Bool = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ThemeIcon(symbol: symbol, size: theme.barSymbolSize,
                          tone: isEnabled ? .normal : .secondary)
                // 文字始终保留（只留图标会让人认不出动作），紧凑时先让快捷键徽标让位。
                Text(title)
                    .font(.system(size: theme.barFont))
                if !compact, let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.iconSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(theme.shortcutChip)
                        )
                }
            }
            .foregroundStyle(isEnabled ? theme.icon : theme.iconSecondary.opacity(0.55))
            .padding(.horizontal, compact ? 6 : 9)
            .frame(height: theme.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle())
        .disabled(!isEnabled)
        .help(help ?? title)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .fill(configuration.isPressed ? theme.pressedOverlay : Color.clear)
            )
    }
}

// MARK: - QuickLook 预览

/// 底栏「预览」的落点。快照里只有文件本身，交给系统 QuickLook 面板最省事：
/// 图片、PDF、视频、Office 文档都由系统自己渲染，我们不用再造一套查看器。
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()

    private var urls: [URL] = []

    /// 已经开着就换成新内容，没开就开一个。
    func present(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}
