import SwiftUI
import AppKit
import Combine
// macOS 27 SDK 把 QuickLookThumbnails 改名成了 QuickLookThumbnailing，两个都兼容。
#if canImport(QuickLookThumbnails)
import QuickLookThumbnails
#elseif canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif
import UniformTypeIdentifiers

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

/// 清单页的展现形式。清单只有一层，分栏视图没有意义，所以只留列表与图标两种。
enum ComposeLayout: String, CaseIterable, Identifiable {
    case list
    case icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return L("列表")
        case .icon: return L("图标")
        }
    }

    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .icon: return "square.grid.2x2"
        }
    }
}

/// 创建压缩包页面的状态。做成单例，主窗口、访达右键、调试入口都能进同一份清单。
final class ComposeArchiveState: ObservableObject {
    static let shared = ComposeArchiveState()

    private enum Key {
        static let layout = "threxo.compose.layout"
    }

    private let defaults = UserDefaults.standard

    @Published var isActive = false
    @Published var items: [ComposeItem] = []
    @Published var selection: Set<String> = []
    @Published var searchText = ""
    @Published var showWizard = false
    @Published var pendingCompress = false
    @Published var isDropTargeted = false
    @Published var errorMessage: String?

    /// 列表 / 图标，跟上一次的选择保持一致。
    @Published var layout: ComposeLayout {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout) }
    }

    init() {
        layout = ComposeLayout(rawValue: UserDefaults.standard.string(forKey: Key.layout) ?? "") ?? .list
    }

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
        appDbg("compose.activate sources=\(sources.count)")
        if !sources.isEmpty { add(sources) }
        appDbg("compose.activate done items=\(items.count) sel=\(selection.count)")
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
        appDbg("compose.select \(id) cmd=\(NSEvent.modifierFlags.contains(.command))")
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

    // MARK: 选中项

    var selectedItems: [ComposeItem] {
        items.filter { selection.contains($0.id) }
    }

    /// 只选了一个才显示「项目详情」；多选显示汇总，空选显示压缩包信息。
    var singleSelection: ComposeItem? {
        let picked = selectedItems
        return picked.count == 1 ? picked[0] : nil
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// 用系统 UTI 拿本地化类型名，比如「PNG 图像」「ZIP 归档」。
    func typeDescription(for item: ComposeItem) -> String {
        if item.isDirectory { return L("文件夹") }
        let ext = item.url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return L("文件") }
        return type.localizedDescription ?? L("文件")
    }
}

// MARK: - 页面

/// 原型 4-1 / 4-2：先攒文件清单，攒够才能保存。
/// 顶栏只放「视图切换 / 移除 / 保存」，加文件统一走底部的大按钮，避免两个入口打架。
/// 右侧详情跟着选中状态切换：没选中看压缩包，选中看文件。
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
            .help(L("返回（放弃这份清单）"))

            HStack(spacing: 6) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            .frame(width: 150)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))

            Picker("", selection: $state.layout) {
                ForEach(ComposeLayout.allCases) { mode in
                    Image(systemName: mode.symbolName)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            .help(L("切换列表与图标"))

            Button {
                state.removeSelected()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(state.selection.isEmpty ? Color.secondary : Color.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(state.selection.isEmpty
                                              ? Color(nsColor: .controlBackgroundColor)
                                              : Color.red))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(state.selection.isEmpty ? 0.10 : 0)))
            }
            .buttonStyle(.borderless)
            .disabled(state.selection.isEmpty)
            .help(state.selection.isEmpty ? L("先选中要移除的文件") : L("移除所选"))

            Button {
                state.showWizard = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(L("保存"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(state.items.isEmpty ? Color.secondary : Color.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(state.items.isEmpty
                                           ? Color(nsColor: .controlBackgroundColor)
                                           : Color.accentColor))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(state.items.isEmpty ? 0.10 : 0)))
            }
            .buttonStyle(.borderless)
            .disabled(state.items.isEmpty)
            .help(state.items.isEmpty ? L("先添加文件，才能保存") : L("下一步设置格式与强度"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 列表 / 图标

    @ViewBuilder
    private var content: some View {
        if state.visibleItems.isEmpty {
            emptyZone
        } else {
            switch state.layout {
            case .list:
                listContent
            case .icon:
                iconContent
            }
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.visibleItems) { item in
                        ComposeRow(item: item, selected: state.selection.contains(item.id)) {
                            state.select(item.id)
                        }
                        .contextMenu { rowMenu(item) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 104, maximum: 128), spacing: 10)]

    private var iconContent: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(state.visibleItems) { item in
                    ComposeCell(item: item, selected: state.selection.contains(item.id)) {
                        state.select(item.id)
                    }
                    .contextMenu { rowMenu(item) }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: ComposeItem) -> some View {
        Button(L("在访达中显示")) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button(L("从清单里移除")) { state.remove(item.id) }
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
                VStack(spacing: 10) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(L("把文件或文件夹拖到这里"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("也可以点下面的「添加文件」"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 400, height: 186)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.22),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { addFiles() }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.items.isEmpty
                         ? L("还没有添加文件")
                         : String(format: L("%d 项 · 合计 %@"), state.items.count,
                                  ByteFormatter.string(state.totalSize)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    if state.selection.count > 1 {
                        Text(String(format: L("已选 %d 项"), state.selection.count))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = state.errorMessage {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)

            // 唯一的添加入口：大按钮，平时就在最显眼的位置。
            Button(action: addFiles) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text(L("添加文件"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 34)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [Color(red: 0.62, green: 0.44, blue: 0.99),
                                 Color(red: 0.52, green: 0.33, blue: 0.94)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                )
                .shadow(color: Color.purple.opacity(0.22), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .help(L("选择要放进压缩包的文件或文件夹"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 右侧详情

    private var detailsTitle: String {
        state.selection.isEmpty ? L("压缩包详情") : L("项目详情")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(detailsTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let item = state.singleSelection {
                        itemSection(item)
                    } else if state.selection.count > 1 {
                        multiSection
                    } else {
                        archiveSection
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    /// 没有选中项时：这份还没保存的压缩包长什么样。
    private var archiveSection: some View {
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

            detailRow(L("大小"), value: state.items.isEmpty ? "—" : ByteFormatter.string(state.totalSize))
            detailRow(L("项目"), value: String(format: L("%d 项"), state.items.count))
            detailRow(L("加密"), value: options.password.isEmpty ? L("否") : L("是"))
            detailRow(L("修改日期"), value: "—")

            Divider().padding(.vertical, 2)

            Text(L("选中一个文件，这里会显示它的信息与预览。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 选中一个：缩略图 + 文件信息。
    private func itemSection(_ item: ComposeItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FileThumbnailView(url: item.url)
                .frame(width: 128, height: 92)

            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(state.typeDescription(for: item))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            detailRow(L("大小"), value: item.size.map { ByteFormatter.string($0) } ?? L("正在计算…"))
            detailRow(L("修改日期"), value: item.modified.map(DateText.detail) ?? "—")
            VStack(alignment: .leading, spacing: 3) {
                Text(L("位置"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 8) {
                Button(L("在访达中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                .controlSize(.small)
                Button(L("从清单里移除")) {
                    state.remove(item.id)
                }
                .controlSize(.small)
            }
        }
    }

    /// 多选：只做汇总，不猜你想看哪一个。
    private var multiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [
                        Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.07),
                    ], startPoint: .top, endPoint: .bottom))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor.opacity(0.75))
            }
            .frame(width: 110, height: 92)

            Text(String(format: L("已选 %d 项"), state.selection.count))
                .font(.system(size: 14.5, weight: .semibold))
            Text(L("多选时只显示汇总信息"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            detailRow(L("合计大小"), value: ByteFormatter.string(state.selectedSize))
            detailRow(L("项目"), value: String(format: L("%d 项"), state.selection.count))

            Divider().padding(.vertical, 2)

            Button(L("移除所选")) { state.removeSelected() }
                .controlSize(.small)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
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

            Text(item.size.map { ByteFormatter.string($0) } ?? L("正在计算…"))
                .foregroundStyle(item.size == nil ? Color.secondary : Color.primary)
                .frame(width: 90, alignment: .trailing)
            Text(item.modified.map { DateText.list($0) } ?? "—")
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

// MARK: - 图标格

private struct ComposeCell: View {
    let item: ComposeItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 46, height: 46)
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text(item.isDirectory ? L("文件夹") : ByteFormatter.string(item.size ?? 0))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(7)
        .frame(height: 108)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
        .help(item.name)
    }
}

// MARK: - 缩略图

/// 详情栏里的预览图。QuickLook 能出图的（图片、PDF、视频首帧、Office 文档）
/// 出真缩略图，出不了就退回系统图标。
///
/// 状态放在 `ThumbnailLoader` 里而不是 `@State`：这个工程在命令行构建时
/// SwiftUI 的 `@State` 宏跑不起来（见 ContentView / SettingsView 的注释）。
private struct FileThumbnailView: View {
    let url: URL

    @StateObject private var loader = ThumbnailLoader()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor))
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .opacity(loader.image == nil ? 1 : 0)
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                }
            }
            .onAppear { loader.load(url: url, size: size) }
            .onChange(of: size) { _, newSize in
                loader.load(url: url, size: newSize)
            }
            .onChange(of: url) { _, _ in
                loader.load(url: url, size: size, force: true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.10))
        )
    }
}

private final class ThumbnailLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private var currentURL: URL?
    private var currentSize: CGSize = .zero

    /// 同一个文件、同一个尺寸不重复请求；`force` 用于切换选中项时清掉旧图。
    func load(url: URL, size: CGSize, force: Bool = false) {
        guard size.width > 1, size.height > 1 else { return }
        if !force, currentURL == url, currentSize == size { return }
        if force || currentURL != url { image = nil }
        currentURL = url
        currentSize = size

        if let cached = ThumbnailCache.shared.image(for: url, size: size) {
            image = cached
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let nsImage = rep.nsImage
            ThumbnailCache.shared.store(nsImage, for: url, size: size)
            DispatchQueue.main.async {
                guard let self, self.currentURL == url, self.currentSize == size else { return }
                self.image = nsImage
            }
        }
    }
}

/// 缩略图缓存：切换选中项来回点时不重复生成。
private final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private func key(_ url: URL, _ size: CGSize) -> NSString {
        "\(url.path)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    func image(for url: URL, size: CGSize) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    func store(_ image: NSImage, for url: URL, size: CGSize) {
        cache.setObject(image, forKey: key(url, size))
    }
}
