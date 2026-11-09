import SwiftUI
import AppKit
import Combine

// MARK: - 数据

/// 清单里的一行。目录大小异步算，先显示占位，算完再回填。
struct ComposeItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let isDirectory: Bool
    var size: Int64?
    var modified: Date?

    var name: String { url.lastPathComponent }
}

/// 创建压缩包页面的状态。做成单例，主窗口、访达右键、调试入口都能进同一份清单。
final class ComposeArchiveState: ObservableObject {
    static let shared = ComposeArchiveState()

    @Published var isActive = false
    @Published var items: [ComposeItem] = []
    @Published var selection: Set<String> = []
    @Published var searchText = ""
    @Published var showWizard = false
    @Published var pendingCompress = false
    @Published var isDropTargeted = false
    @Published var errorMessage: String?

    /// 进入创建页。`sources` 非空时预填，供访达右键「压缩为…」使用。
    func activate(sources: [URL] = []) {
        items = []
        selection = []
        searchText = ""
        showWizard = false
        pendingCompress = false
        errorMessage = nil
        isDropTargeted = false
        isActive = true
        if !sources.isEmpty { add(sources) }
    }

    func deactivate() {
        isActive = false
        showWizard = false
        pendingCompress = false
        items = []
        selection = []
        searchText = ""
        errorMessage = nil
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var added = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, !items.contains(where: { $0.id == path }) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: path)
            let dir = isDir.boolValue
            items.append(ComposeItem(
                id: path,
                url: URL(fileURLWithPath: path),
                isDirectory: dir,
                size: dir ? nil : (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attrs?[.modificationDate] as? Date
            ))
            added += 1
            if dir { computeDirectorySize(for: path) }
        }
        if added > 0 { errorMessage = nil }
        else { errorMessage = L("这些文件已经加进来了，或者已经不在原位置。") }
    }

    private func computeDirectorySize(for path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var total: Int64 = 0
            if let enumerator = fm.enumerator(atPath: path) {
                for case let name as String in enumerator {
                    let full = (path as NSString).appendingPathComponent(name)
                    if let size = (try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber {
                        total += size.int64Value
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let index = self.items.firstIndex(where: { $0.id == path }) else { return }
                self.items[index].size = total
            }
        }
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        items.removeAll { selection.contains($0.id) }
        selection = []
        errorMessage = nil
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        selection.remove(id)
        errorMessage = nil
    }

    func select(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    var visibleItems: [ComposeItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + ($1.size ?? 0) }
    }

    var urls: [URL] { items.map(\.url) }
}

// MARK: - 页面

/// 原型 4-1 / 4-2：在主窗口里先攒文件清单，攒够才能保存。
/// 保存时弹出 `CompressWizardView`（用途 / 强度 / 概览），确认后再走系统保存面板。
struct ComposeArchiveView: View {
    @ObservedObject var state: ComposeArchiveState
    @ObservedObject var options: CompressionOptions
    @EnvironmentObject var model: AppModel

    private var displayName: String {
        String(format: L("未命名压缩包.%@"), options.format.fileExtension)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
                Divider()
                bottomBar
            }
            Divider()
            details
                .frame(width: 258)
        }
        .frame(minWidth: 900, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            state.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            state.isDropTargeted = targeted
        }
        .overlay {
            if state.isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background {
            Button("") { state.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
                .disabled(state.selection.isEmpty)
        }
        .sheet(isPresented: $state.showWizard, onDismiss: startPendingCompress) {
            CompressWizardView(
                options: options,
                hasSources: true,
                sourceCount: state.items.count,
                onCancel: { state.showWizard = false },
                onConfirm: {
                    // 先收 sheet，再弹系统保存面板，避免两个 modal 叠在一起。
                    state.pendingCompress = true
                    state.showWizard = false
                }
            )
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                state.deactivate()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(L("返回"))

            HStack(spacing: 6) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L("搜索"), text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !state.searchText.isEmpty {
                    Button {
                        state.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 170)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))

            Button {
                addFiles()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.borderless)
            .help(L("添加文件"))

            Button {
                state.removeSelected()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12.5))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.borderless)
            .disabled(state.selection.isEmpty)
            .help(L("移除所选"))

            Button {
                state.showWizard = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(state.items.isEmpty ? Color.secondary : Color.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(state.items.isEmpty
                                              ? Color(nsColor: .controlBackgroundColor)
                                              : Color.accentColor))
            }
            .buttonStyle(.borderless)
            .disabled(state.items.isEmpty)
            .help(state.items.isEmpty ? L("先添加文件，才能保存") : L("保存压缩包"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if state.visibleItems.isEmpty {
            emptyZone
        } else {
            VStack(spacing: 0) {
                tableHeader
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.visibleItems) { item in
                            ComposeRow(item: item, selected: state.selection.contains(item.id)) {
                                state.select(item.id)
                            }
                            .contextMenu {
                                Button(L("从清单里移除")) { state.remove(item.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text(L("名称"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("大小"))
                .frame(width: 90, alignment: .trailing)
            Text(L("修改时间"))
                .frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var emptyZone: some View {
        VStack {
            Spacer(minLength: 0)
            if state.items.isEmpty {
                Button(action: addFiles) {
                    VStack(spacing: 10) {
                        Image(systemName: "square.on.square.dashed")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(L("添加文件到压缩包"))
                            .font(.system(size: 16, weight: .semibold))
                        Text(L("点击添加文件，或直接将文件拖到这里"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 380, height: 180)
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.primary.opacity(0.22),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
                }
                .buttonStyle(.plain)
            } else {
                Text(L("没有匹配的文件"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.items.isEmpty
                     ? L("还没有添加文件")
                     : String(format: L("%d 项 · 合计 %@"), state.items.count,
                              ByteFormatter.string(state.totalSize)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if let error = state.errorMessage {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button(L("取消")) { state.deactivate() }
            Button(L("添加文件")) { addFiles() }
            if state.items.isEmpty {
                Button(L("保存压缩包…")) { }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .help(L("先添加文件，才能保存"))
            } else {
                Button(L("保存压缩包…")) { state.showWizard = true }
                    .buttonStyle(.borderedProminent)
                    .help(L("下一步设置格式与强度"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 右侧详情

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("压缩包详情"))
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [
                                Color.purple.opacity(0.22), Color.purple.opacity(0.08),
                            ], startPoint: .top, endPoint: .bottom))
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.purple.opacity(0.75))
                    }
                    .frame(width: 110, height: 100)

                    Text(displayName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: L("%@ 压缩包"), options.format.displayName))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 2)

                    detailRow(L("大小"), value: ByteFormatter.string(state.totalSize))
                    detailRow(L("项目"), value: String(format: L("%d 项"), state.items.count))
                    detailRow(L("加密"), value: options.password.isEmpty ? L("否") : L("是"))
                    detailRow(L("修改日期"), value: "—")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5))
        }
    }

    // MARK: - 动作

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L("选择要放进压缩包的文件或文件夹")
        panel.prompt = L("添加")
        guard panel.runModal() == .OK else { return }
        state.add(panel.urls)
    }

    /// 向导确认、sheet 收起之后才调系统保存面板。
    /// 只有真正开始压缩才回到主页面；用户在保存面板点「取消」时清单原样留着。
    private func startPendingCompress() {
        guard state.pendingCompress else { return }
        state.pendingCompress = false
        let urls = state.urls
        guard !urls.isEmpty else { return }
        model.compress(sources: urls) { [weak state] in
            state?.deactivate()
        }
    }
}

// MARK: - 列表行

private struct ComposeRow: View {
    let item: ComposeItem
    let selected: Bool
    let action: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 17, height: 17)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ByteFormatter.string(item.size ?? 0))
                .foregroundStyle(item.size == nil ? Color.secondary : Color.primary)
                .frame(width: 90, alignment: .trailing)
            Text(item.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
