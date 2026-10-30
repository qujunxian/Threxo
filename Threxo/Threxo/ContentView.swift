import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 用 ObservableObject 代替 @State：命令行构建环境下 @State 宏依赖的
    /// swift-plugin-server 会被沙箱拦截，这里绕开它。
    @StateObject private var drop = DropState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.finderExtensionEnabled {
                extensionBanner
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 460)
        .onAppear { model.refreshFinderExtensionState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFinderExtensionState()
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.receiveOpenFiles(urls)
            return true
        } isTargeted: { targeted in
            drop.isTargeted = targeted
        }
        .overlay {
            if drop.isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.archiveURL?.lastPathComponent ?? "千梭")
                    .font(.title3.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("压缩…") { model.compress() }
                .disabled(model.isBusy)
            Button("打开归档…") { model.openArchive() }
                .disabled(model.isBusy)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var subtitle: String {
        guard let url = model.archiveURL else {
            return "拖入压缩包即可查看内容 · 拖入文件或文件夹即可压缩"
        }
        return "\(model.fileCount) 个文件 · 解压后 \(ByteFormatter.string(model.totalUncompressedSize)) · \(url.deletingLastPathComponent().path)"
    }

    // MARK: - Finder extension banner

    private var extensionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("访达右键菜单尚未启用")
                    .font(.callout.weight(.medium))
                Text("到「系统设置 → 通用 → 登录项与扩展」，在访达扩展里打开「千梭」，右键压缩包即可一键解压。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") { model.refreshFinderExtensionState() }
                .controlSize(.small)
            Button("前往设置") { model.openExtensionSettings() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isBusy && model.entries.isEmpty {
            centered {
                ProgressView()
                Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            }
        } else if model.entries.isEmpty {
            emptyState
        } else if !model.treeNodes.isEmpty {
            List(model.treeNodes, children: \.children, selection: $model.selection) { node in
                row(icon: node.isDirectory ? "folder" : "doc",
                    tint: node.isDirectory ? Color.accentColor : Color.secondary,
                    name: node.name,
                    detail: node.isDirectory ? nil : ByteFormatter.string(node.size))
            }
            .listStyle(.inset)
        } else {
            // 超大归档（> 2 万条）回退到扁平列表，避免建树卡顿。
            List(model.entries, id: \.path, selection: $model.selection) { entry in
                row(icon: entry.isDirectory ? "folder" : "doc",
                    tint: entry.isDirectory ? Color.accentColor : Color.secondary,
                    name: entry.path,
                    detail: entry.isDirectory ? nil : ByteFormatter.string(entry.size))
            }
            .listStyle(.inset)
        }
    }

    private func row(icon: String, tint: Color, name: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        centered {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("把压缩包拖到这里")
                .font(.headline)
            Text("也可以直接拖入文件或文件夹，立即打包成 ZIP")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("打开归档…") { model.openArchive() }
                .controlSize(.small)
                .padding(.top, 4)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if model.isBusy {
                ProgressView(value: Double(model.progress), total: 100) {
                    HStack(spacing: 6) {
                        Text("\(model.statusText) \(model.progress)%")
                            .font(.caption)
                        if let item = model.currentItem {
                            Text("· \(item)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .progressViewStyle(.linear)
            }

            HStack(spacing: 8) {
                statusLabel
                Spacer()
                if model.isBusy {
                    Button("取消") { model.cancel() }
                } else if model.archiveURL != nil {
                    Button("解压到…") { model.extractAllChoosingDestination() }
                        .disabled(model.selection.isEmpty == false ? false : model.entries.isEmpty)
                    if model.hasSelection {
                        Button("解压所选 \(model.selection.count) 项") { model.extractSelected() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("解压") { model.extractAll() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.entries.isEmpty)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let error = model.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } else {
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 拖拽高亮状态。独立成 ObservableObject，避免在 View 里使用 @State 宏。
final class DropState: ObservableObject {
    @Published var isTargeted = false
}

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = Foundation.ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// 预览宏（#Preview）依赖 swift-plugin-server，命令行构建下沙箱会拦截插件进程，暂不启用。
// #Preview { ContentView().environmentObject(AppModel.shared) }
