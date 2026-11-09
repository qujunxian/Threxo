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

/// 分栏视图里「某个文件夹里的一个条目」。只用来展示，不参与清单增删。
struct ComposeChild: Identifiable, Equatable {
    let id: String
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?

    var name: String { url.lastPathComponent }
}

/// 清单页的展现形式，三档与解压页保持一致。
/// 「分栏」在这里是顺着文件夹往里看：清单本身只有一层，但加进来的文件夹可以展开看内容。
enum ComposeLayout: String, CaseIterable, Identifiable {
    case list
    case icon
    case column

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return L("列表")
        case .icon: return L("图标")
        case .column: return L("分栏")
        }
    }

    var symbolName: String {
        switch self {
        case .list: return "list.bullet"
        case .icon: return "square.grid.2x2"
        case .column: return "rectangle.split.3x1"
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

    /// 列表 / 图标 / 分栏，跟上一次的选择保持一致。
    @Published var layout: ComposeLayout {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout) }
    }

    /// 分栏视图当前钻到了哪些文件夹（下标 0 是清单里的顶层文件夹）。
    @Published var columnPath: [String] = []
    /// 分栏视图每一列的缓存：path → 子项。
    @Published private(set) var columnChildren: [String: [ComposeChild]] = [:]
    /// 正在读目录的文件夹，给那一列显示加载态。
    @Published private(set) var columnLoading: Set<String> = []

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
        columnPath = []
        columnChildren = [:]
        columnLoading = []
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
        columnPath = []
        columnChildren = [:]
        columnLoading = []
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

    /// 底栏「预览」能不能点：只认选中的单个文件。
    var previewItem: ComposeItem? {
        guard let item = singleSelection, !item.isDirectory else { return nil }
        return item
    }

    // MARK: 分栏视图的子目录

    func children(of folder: String) -> [ComposeChild]? {
        columnChildren[folder]
    }

    func isLoadingChildren(_ folder: String) -> Bool {
        columnLoading.contains(folder)
    }

    /// 读一个文件夹的内容。结果缓存起来，来回切列不重复读盘。
    func loadChildren(of folder: String) {
        guard columnChildren[folder] == nil, !columnLoading.contains(folder) else { return }
        columnLoading.insert(folder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = (try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: folder),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
            // 一列放不下几千项，读前 600 个足够看清结构了。
            let children = urls.prefix(600).compactMap { url -> ComposeChild? in
                let values = try? url.resourceValues(forKeys: keys)
                let isDir = values?.isDirectory ?? false
                return ComposeChild(
                    id: url.path,
                    url: url,
                    isDirectory: isDir,
                    size: isDir ? nil : Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.columnChildren[folder] = children
                self.columnLoading.remove(folder)
            }
        }
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
    @Environment(\.appTheme) private var theme

    private var displayName: String {
        String(format: L("未命名压缩包.%@"), options.format.fileExtension)
    }

    var body: some View {
        // 以前这里硬写 minWidth: 900，窗口缩到 760 时内容直接被裁掉、控件互相压住。
        // 改成按实际宽度收：先藏详情栏，再藏搜索框，按钮永远有位置。
        GeometryReader { geo in
            let showDetails = geo.size.width >= 880
            let showSearch = geo.size.width >= 720
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar(showSearch: showSearch)
                    Divider()
                    content
                    Divider()
                    bottomBar
                }
                if showDetails {
                    Divider()
                    details
                        .frame(width: 258)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private func toolbar(showSearch: Bool) -> some View {
        HStack(spacing: 10) {
            ThemeIconButton(symbol: "chevron.left", help: L("返回（放弃这份清单）")) {
                state.deactivate()
            }

            HStack(spacing: 6) {
                ThemeIcon(symbol: "doc.zipper", size: 12, tone: .secondary)
                Text(displayName)
                    .font(.system(size: theme.barFont, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 220)
            .background(Capsule().fill(theme.surface))
            .overlay(Capsule().strokeBorder(theme.pillBorder))

            Spacer(minLength: 8)

            // 窗口变窄时先收搜索框，保证视图切换和两个主按钮不被挤掉。
            if showSearch {
                HStack(spacing: 5) {
                    ThemeIcon(symbol: "magnifyingglass", size: 11, tone: .secondary)
                    TextField(L("搜索"), text: $state.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: theme.barFont))
                    if !state.searchText.isEmpty {
                        Button {
                            state.searchText = ""
                        } label: {
                            ThemeIcon(symbol: "xmark.circle.fill", size: 10, tone: .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 150)
                .themeSurface()
            }

            Picker("", selection: $state.layout) {
                ForEach(ComposeLayout.allCases) { mode in
                    ThemeIcon(symbol: mode.symbolName, size: 11)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)
            .help(L("切换列表、图标与分栏"))

            ThemeIconButton(
                symbol: "trash",
                tone: .danger,
                filled: !state.selection.isEmpty,
                isEnabled: !state.selection.isEmpty,
                help: state.selection.isEmpty ? L("先选中要移除的文件") : L("移除所选")
            ) {
                state.removeSelected()
            }

            PrimaryActionButton(
                title: L("保存"),
                symbol: "square.and.arrow.down",
                compact: true,
                isEnabled: !state.items.isEmpty,
                help: state.items.isEmpty ? L("先添加文件，才能保存") : L("下一步设置格式与强度")
            ) {
                state.showWizard = true
            }
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
            case .column:
                columnContent
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

    // MARK: - 分栏

    private struct ComposeColumn {
        let folder: String
        let children: [ComposeChild]
        let isLoading: Bool
    }

    /// 第 0 列是清单本身，之后每一列是上一列里选中文件夹的内容。
    private var columnData: [ComposeColumn] {
        var result: [ComposeColumn] = []
        let top = state.visibleItems.map {
            ComposeChild(id: $0.id, url: $0.url, isDirectory: $0.isDirectory,
                         size: $0.size, modified: $0.modified)
        }
        result.append(ComposeColumn(folder: "", children: top, isLoading: false))

        for path in state.columnPath {
            let children = state.children(of: path)
            result.append(ComposeColumn(folder: path,
                                        children: children ?? [],
                                        isLoading: children == nil))
            if children == nil { break }
        }
        return result
    }

    private var columnContent: some View {
        let cols = columnData
        return ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(Array(cols.enumerated()), id: \.offset) { index, column in
                    columnList(index: index, column: column)
                        .frame(width: 220)
                    if index < cols.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: state.columnPath) { _, path in
            for folder in path {
                state.loadChildren(of: folder)
            }
        }
        // 搜索时只看匹配的顶层项，别把上一次钻进去的列留在旁边。
        .onChange(of: state.searchText) { _, _ in
            state.columnPath = []
        }
    }

    private func columnList(index: Int, column: ComposeColumn) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if column.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("正在读取…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                } else if column.children.isEmpty {
                    Text(index == 0 ? L("还没有添加文件") : L("空文件夹"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(column.children) { child in
                        columnRow(child, index: index)
                            .onTapGesture { dive(child, index: index) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(index == 0 ? Color.clear : Color(nsColor: .textBackgroundColor).opacity(0.25))
    }

    private func columnRow(_ child: ComposeChild, index: Int) -> some View {
        let selected = isColumnSelected(child, index: index)
        return HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: child.url.path))
                .resizable()
                .frame(width: 15, height: 15)
            Text(child.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if child.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Text(ByteFormatter.string(child.size ?? 0))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
    }

    private func isColumnSelected(_ child: ComposeChild, index: Int) -> Bool {
        if index == 0 { return state.selection.contains(child.id) }
        return state.columnPath.count > index && state.columnPath[index] == child.id
    }

    /// 点文件夹就往里钻一层，后面的列自动截断；点文件不改变清单的选择。
    private func dive(_ child: ComposeChild, index: Int) {
        guard child.isDirectory else { return }
        state.columnPath = Array(state.columnPath.prefix(index)) + [child.id]
        if index == 0 {
            state.select(child.id)
        }
        state.loadChildren(of: child.id)
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
        ActionBar {
            ActionPill {
                ActionButton(
                    title: L("预览"),
                    symbol: "eye",
                    shortcut: L("空格"),
                    isEnabled: state.previewItem != nil,
                    help: state.previewItem == nil
                        ? L("选中一个文件后就能预览")
                        : L("用系统 QuickLook 预览选中的文件（空格）")
                ) { model.previewCurrent() }
            }

            CompactHidden {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(state.items.isEmpty
                             ? L("还没有添加文件")
                             : String(format: L("%d 项 · 合计 %@"), state.items.count,
                                      ByteFormatter.string(state.totalSize)))
                            .font(.system(size: theme.barFont))
                            .foregroundStyle(theme.iconSecondary)
                        if state.selection.count > 1 {
                            Text(String(format: L("已选 %d 项"), state.selection.count))
                                .font(.system(size: theme.barFont))
                                .foregroundStyle(theme.iconSecondary)
                        }
                    }
                    .lineLimit(1)
                    if let error = state.errorMessage {
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.danger)
                            .lineLimit(1)
                    }
                }
            }
        } trailing: {
            // 与解压页「解压到…」共用同一个主操作组件，两页底栏从此是一套。
            PrimaryActionButton(
                title: L("添加文件"),
                symbol: "plus",
                help: L("选择要放进压缩包的文件或文件夹")
            ) { addFiles() }
        }
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
