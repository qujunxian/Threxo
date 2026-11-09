import SwiftUI
import AppKit
import QuickLookUI

// MARK: - 底部操作条

/// 解压页与创建页共用的底栏外壳：左边一组动作，右边主操作。
///
/// 只统一「壳」——高度、内边距、胶囊容器、按钮的字号与快捷键小方块；
/// 具体放哪些动作由各页面自己决定，这样两页看着是一套，又不会互相绑架。
struct ActionBar<Leading: View, Trailing: View>: View {
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    init(@ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// 底栏里的浅色胶囊容器：把几个动作拢成一组。
struct ActionPill<Content: View>: View {
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
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// 底栏里的单个动作：图标 + 文字 + 可选快捷键小方块。
struct ActionButton: View {
    let title: String
    let symbol: String
    var shortcut: String?
    var isEnabled: Bool = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5))
                Text(title)
                    .font(.system(size: 11.5))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5)
                                .fill(Color.primary.opacity(0.07))
                        )
                }
            }
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.55))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(ActionButtonStyle())
        .disabled(!isEnabled)
        .help(help ?? title)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.10) : Color.clear)
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
