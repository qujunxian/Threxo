import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    /// 用 ObservableObject 代替 @State：命令行构建环境下 @State 宏依赖的
    /// swift-plugin-server 会被沙箱拦截，这里绕开它。
    @StateObject private var drop = DropState()
    /// 创建压缩包的文件清单页（原型 4-1）。激活时整个主窗口切成那一页。
    @StateObject private var compose = ComposeArchiveState.shared
    @StateObject private var browser = BrowserState()
    @ObservedObject private var options = CompressionOptions.shared

    var body: some View {
        Group {
            // 创建压缩包：切到文件清单页（原型 4-1），攒够内容才能保存。
            if compose.isActive {
                ComposeArchiveView(state: compose, options: options)
            } else if model.archiveURL == nil && !model.isBusy {
                // 没打开归档时按原型 3 走独立的欢迎态：顶部品牌 + 设置入口，
                // 中央大字与两个主按钮，不显示工具栏和状态栏。
                emptyWindow
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                    if model.archiveURL != nil, !model.entries.isEmpty, !model.isBusy {
                        Divider()
                        hintBar
                    }
                    Divider()
                    footer
                }
            }
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
        .overlay {
            if let prompt = model.extractCompletionPrompt {
                ZStack {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { }   // 遮罩吃掉点击，别让操作穿透到列表
                    ExtractCompletionCard(prompt: prompt) { moveToTrash in
                        model.resolveExtractCompletion(moveToTrash: moveToTrash)
                    }
                }
            }
        }
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordSheet(
                prompt: prompt,
                onSubmit: { model.submitPassword($0) },
                onCancel: { model.cancelPassword() }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 19))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.archiveURL?.lastPathComponent ?? L("千梭"))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.archiveURL == nil {
            emptyWindow
        } else {
            ArchiveBrowserView(model: model, browser: browser, drop: drop)
        }
    }

    /// 两件事都不容易被发现，用一行灰字点出来。
    ///
    /// 这条提示栏同时兼任「加进归档根目录」的投放点：列表下方那片空白属于
    /// `NSTableView`，指针停在那里时拖拽会被表格吞掉（行级接收器只覆盖有行的
    /// 区域），所以在列表外面留一个稳定可用的落点。
    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 10))
            Text("把条目拖到访达即解压到那里 · 把文件拖到文件夹行、详情区或这条提示栏，就加进这个归档")
                .font(.caption2)
            Spacer()
        }
        .foregroundStyle(drop.isTargeted ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(drop.isTargeted ? 0.07 : 0.03))
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.addDroppedFiles(urls, toFolder: nil)
            return true
        } isTargeted: { inside in
            drop.isTargeted = inside
        }
    }

    private var emptyWindow: some View {
        ZStack(alignment: .top) {
            // 渐变是固定的浅粉紫，深色模式下文字会变成白色，读不清；
            // 所以按外观切换一套深色渐变。
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.19, green: 0.12, blue: 0.18),
                       Color(red: 0.11, green: 0.12, blue: 0.21)]
                    : [Color(red: 1.0, green: 0.95, blue: 0.95).opacity(0.85),
                       Color(red: 0.93, green: 0.94, blue: 1.0).opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                emptyTopBar
                Spacer(minLength: 0)

                VStack(spacing: 16) {
                    Text(L("欢迎！拖入文件以开始"))
                        .font(.system(size: 30, weight: .bold))
                    Text(String(format: L("拖入压缩包查看内容，拖入文件或文件夹打包成 %@"),
                                options.format.displayName))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            model.openArchive()
                        } label: {
                            Label(L("打开压缩包"), systemImage: "folder")
                                .frame(minWidth: 132)
                        }
                        .controlSize(.large)

                        Button {
                            compose.activate()
                        } label: {
                            Label(L("创建压缩包"), systemImage: "plus")
                                .frame(minWidth: 132)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(.top, 6)
                }

                Spacer(minLength: 0)
                emptyFootnote
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 顶部居中放品牌，右侧留一个设置入口，跟原型 3 一致。
    private var emptyTopBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(L("千梭"))
                    .font(.system(size: 16, weight: .semibold))
            }
            HStack {
                Spacer()
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.10)))
                }
                .buttonStyle(.borderless)
                .help(L("设置"))
            }
        }
    }

    /// 扩展没启用时给一行小字，不占掉欢迎态的留白。
    @ViewBuilder
    private var emptyFootnote: some View {
        if !model.finderExtensionEnabled {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 10))
                Text(L("访达右键菜单还没启用"))
                    .font(.system(size: 10.5))
                Button(L("前往设置")) { model.openExtensionSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .foregroundStyle(.secondary)
        }
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


// MARK: - 解压完成卡片

/// 参考原型：解压成功后问一次原包去留。
/// 选「保留」继续看归档，选「移入废纸篓」则清空归档并关掉主窗口。
private struct ExtractCompletionCard: View {
    let prompt: ExtractCompletionPrompt
    let onChoose: (Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            Text(L("解压完成"))
                .font(.system(size: 14, weight: .bold))
            Text(String(format: L("是否将「%@」移入废纸篓？"), prompt.archive.lastPathComponent))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(L("保留压缩包")) { onChoose(false) }
                    .controlSize(.large)
                Button(L("移入废纸篓")) { onChoose(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
