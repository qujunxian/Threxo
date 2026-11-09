import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 用 ObservableObject 代替 @State：命令行构建环境下 @State 宏依赖的
    /// swift-plugin-server 会被沙箱拦截，这里绕开它。
    @StateObject private var drop = DropState()
    @StateObject private var wizard = CompressWizardState()
    @StateObject private var browser = BrowserState()
    @ObservedObject private var options = CompressionOptions.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.finderExtensionEnabled {
                extensionBanner
                Divider()
            }
            content
            if model.archiveURL != nil, !model.entries.isEmpty, !model.isBusy {
                Divider()
                hintBar
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { model.refreshFinderExtensionState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFinderExtensionState()
        }
        .dropDestination(for: URL.self) { urls, _ in
            // 已经开着归档时，拖进来的文件是「加进这个包」；没开归档才按打开/压缩处理。
            // 想换一个归档看，就拖到标题栏（见 header 的 dropDestination）。
            if model.archiveURL != nil {
                model.addDroppedFiles(urls, toFolder: nil)
            } else {
                model.receiveOpenFiles(urls)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .threxoFocusSearch)) { _ in
            browser.focusSearch()
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordSheet(
                prompt: prompt,
                onSubmit: { model.submitPassword($0) },
                onCancel: { model.cancelPassword() }
            )
        }
        .sheet(isPresented: $wizard.isPresented, onDismiss: startPendingCompress) {
            CompressWizardView(
                options: options,
                onCancel: { wizard.isPresented = false },
                onConfirm: {
                    // 面板收掉之后再弹系统面板，否则两个 modal 叠在一起会卡住。
                    wizard.pendingCompress = true
                    wizard.isPresented = false
                }
            )
        }
    }

    /// 向导确认后接着走「选源 → 选保存位置」两步，用的仍是 `AppModel.compress()`。
    private func startPendingCompress() {
        guard wizard.pendingCompress else { return }
        wizard.pendingCompress = false
        model.compress()
    }

    // MARK: - Format picker

    /// 顶栏右侧的格式选择器：改的是「压缩成什么」。
    private var formatMenu: some View {
        Menu {
            Picker(L("压缩格式"), selection: $options.format) {
                ForEach(ArchiveFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: options.format.symbolName)
                    .foregroundStyle(.orange)
                Text(options.format.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("选择压缩格式"))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.archiveURL?.lastPathComponent ?? L("千梭"))
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

            formatMenu

            Button("压缩…") { wizard.isPresented = true }
                .disabled(model.isBusy)
                .help(L("打开创建压缩包向导"))
            Button("打开归档…") { model.openArchive() }
                .disabled(model.isBusy)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(drop.headerTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            // 标题栏是「换一个归档」的落点：列表区域留给「加进归档」。
            guard let archive = urls.first(where: AppModel.isArchiveURL) else { return false }
            model.load(archive: archive)
            return true
        } isTargeted: { targeted in
            drop.headerTargeted = targeted
        }
    }

    private var subtitle: String {
        guard let url = model.archiveURL else {
            return L("拖入压缩包即可查看内容 · 拖入文件或文件夹即可压缩")
        }
        return String(
            format: L("%d 个文件 · 解压后 %@ · %@"),
            model.fileCount,
            ByteFormatter.string(model.totalUncompressedSize),
            url.deletingLastPathComponent().path
        )
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
        if model.archiveURL == nil {
            emptyState
        } else {
            ArchiveBrowserView(model: model, browser: browser, drop: drop)
        }
    }

    /// 两件事都不容易被发现，用一行灰字点出来。
    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 10))
            Text("把条目拖到访达即解压到那里 · 把文件拖到文件夹行或列表空白处，就加进这个归档")
                .font(.caption2)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    private var emptyState: some View {
        centered {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("把压缩包拖到这里")
                .font(.headline)
            Text(String(format: L("也可以直接拖入文件或文件夹，立即打包成 %@"), options.format.displayName))
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
                        Text(verbatim: "\(model.statusText) \(model.progress)%")
                            .font(.caption)
                        if let item = model.currentItem {
                            Text(verbatim: "· \(item)")
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
                    Button("解压到…") { model.extractChoosingDestination() }
                        .disabled(model.entries.isEmpty)
                    if model.hasSelection {
                        Button("解压到此处") { model.extractPaths(Array(model.selection), choosingDestination: false) }
                            .help(L("解到压缩包所在文件夹，重名自动改名，不覆盖已有文件"))
                        Button(String(format: L("解压所选 %d 项"), model.selection.count)) { model.extractSelected() }
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
        // 启动错误优先：压缩引擎不可用时，其他提示都没有意义。
        if let startup = model.startupError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(startup)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } else if let error = model.errorMessage {
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
    /// 文件拖到窗口空白处。
    @Published var isTargeted = false
    /// 文件正悬在哪一行的层级上（该行的 path）。
    @Published var rowTarget: String?
    /// 归档拖到标题栏（= 换一个打开）。
    @Published var headerTargeted = false
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
