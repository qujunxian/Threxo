import SwiftUI
import AppKit
import Combine

// MARK: - 界面状态

/// 列表呈现相关的临时状态：详情栏宽窄、展开的目录、图标视图的当前位置。
/// 只放「纯界面」的东西；条目、筛选、排序都在 `AppModel` 里，因为它们要参与建树。
final class BrowserState: ObservableObject {
    private enum Key {
        static let showDetail = "threxo.browse.showDetail"
        static let detailWidth = "threxo.browse.detailWidth"
        static let showPacked = "threxo.browse.showPackedColumn"
    }

    private let defaults = UserDefaults.standard

    /// 右侧详情栏是否展开。默认展开——第一次打开归档时，概览就是最好的说明。
    @Published var showDetail: Bool {
        didSet { defaults.set(showDetail, forKey: Key.showDetail) }
    }

    /// 详情栏宽度，拖动左边缘可调，跨会话记忆。
    @Published var detailWidth: CGFloat {
        didSet { defaults.set(Double(detailWidth), forKey: Key.detailWidth) }
    }

    /// 「压缩后」列是否显示。默认显示；列多的时候可以收起来给名字腾地方。
    @Published var showPackedColumn: Bool {
        didSet { defaults.set(showPackedColumn, forKey: Key.showPacked) }
    }

    /// 列表里展开了哪些目录（按路径）。
    @Published var expanded: Set<String> = []

    /// 图标视图当前所在层级；空字符串是根。
    @Published var iconPath: [String] = []

    /// 分栏视图每一列选中的那一项。
    @Published var columnPath: [String] = []

    /// 每次 ⌘F 递增，搜索框据此把自己切到第一响应者。
    @Published var focusToken = 0

    init() {
        showDetail = UserDefaults.standard.object(forKey: Key.showDetail) as? Bool ?? true
        let saved = UserDefaults.standard.double(forKey: Key.detailWidth)
        detailWidth = saved >= 200 && saved <= 460 ? CGFloat(saved) : 260
        showPackedColumn = UserDefaults.standard.object(forKey: Key.showPacked) as? Bool ?? true
    }

    /// 换一个归档时清掉层级位置，展开状态按新树重新决定。
    func prepare(for roots: [ArchiveNode]) {
        columnPath = []
        // 只有一个根目录的包（很常见：zip 里套一层文件夹）直接展开 / 进入，
        // 不然打开就看到孤零零一行，还要多点一次。
        if roots.count == 1, let only = roots.first, only.isDirectory {
            expanded = [only.path]
            iconPath = [only.path]
            columnPath = [only.path]
        } else {
            expanded = []
            iconPath = []
        }
    }

    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
        }
    }

    func focusSearch() { focusToken += 1 }
}

// MARK: - 主视图

struct ArchiveBrowserView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: BrowserState
    let drop: DropState

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            browserBar
            Divider()
            HStack(spacing: 0) {
                browseArea
                if browser.showDetail {
                    resizeHandle
                    DetailPanelView(model: model, browser: browser)
                        .frame(width: browser.detailWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .onAppear { browser.prepare(for: model.treeNodes) }
        .onChange(of: model.archiveURL) { _, _ in
            browser.prepare(for: model.treeNodes)
        }
        // 拖进折叠的文件夹之后，把那一串目录展开，新条目才看得见（T-08）。
        .onChange(of: model.revealRequest) { _, request in
            guard let request else { return }
            browser.expanded.formUnion(request.folders)
        }
    }

    /// 详情栏左边缘的拖动条。往里拖变窄，往外拖变宽，松手即写盘。
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: 7)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // 越往左拖越宽，所以用减法。
                        let proposed = browser.detailWidth - value.translation.width
                        browser.detailWidth = min(460, max(200, proposed))
                    }
            )
    }

    // MARK: 顶部条

    private var browserBar: some View {
        HStack(spacing: 10) {
            SearchField(
                text: $model.searchText,
                focusToken: browser.focusToken,
                placeholder: L("搜索名称或路径")
            )
            .frame(width: 220)

            if !model.searchText.isEmpty {
                Text(String(format: L("%d 项匹配"), model.entries.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("", selection: $settings.browseMode) {
                ForEach(SettingsStore.BrowseMode.allCases) { mode in
                    Image(systemName: mode.symbolName)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 118)
            .help(L("切换列表、图标、分栏"))

            Button {
                settings.showAuxiliaryItems.toggle()
            } label: {
                Image(systemName: settings.showAuxiliaryItems ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(settings.showAuxiliaryItems ? L("隐藏 __MACOSX 等辅助项目") : L("显示 __MACOSX 等辅助项目"))

            Menu {
                Toggle(L("显示「压缩后」列"), isOn: $browser.showPackedColumn)
                Toggle(L("显示详情栏"), isOn: $browser.showDetail)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("列与面板"))

            Button {
                browser.showDetail.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(browser.showDetail ? L("隐藏详情") : L("显示详情"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 三视图

    @ViewBuilder
    private var browseArea: some View {
        if model.isBusy && model.entries.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            emptyResult
        } else {
            switch settings.browseMode {
            case .list:
                ArchiveListView(model: model, browser: browser, drop: drop)
            case .icon:
                ArchiveIconView(model: model, browser: browser)
            case .column:
                ArchiveColumnView(model: model, browser: browser)
            }
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.searchText.isEmpty ? L("这个归档是空的") : L("没有匹配的条目"))
                .font(.callout)
            if !model.searchText.isEmpty {
                Button("清除搜索") { model.searchText = "" }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 列表视图

struct ArchiveListView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: BrowserState
    let drop: DropState

    /// 树被拍平之后的行。自己拍平而不是用 `List(children:)`，
    /// 是因为后者会把整行一起缩进，数字列就会随层级左右乱跳。
    private struct Row: Identifiable {
        let node: ArchiveNode
        let depth: Int
        var id: String { node.path }
    }

    private var rows: [Row] {
        var out: [Row] = []
        flatten(model.treeNodes, depth: 0, into: &out)
        return out
    }

    private func flatten(_ nodes: [ArchiveNode], depth: Int, into out: inout [Row]) {
        for node in nodes {
            out.append(Row(node: node, depth: depth))
            if node.isDirectory, browser.expanded.contains(node.path), let children = node.children {
                flatten(children, depth: depth + 1, into: &out)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.treeNodes.isEmpty {
                // 超大归档（> 2 万条）回退扁平列表。这里直接用 `entries`，
                // 不再为每一行造一个 ArchiveNode——十万级条目那样会白扔十万次分配。
                List(model.entries, id: \.path, selection: $model.selection) { entry in
                    rowBody(
                        name: entry.path,
                        path: entry.path,
                        size: entry.size,
                        packedSize: entry.packedSize,
                        modified: entry.modified,
                        isDirectory: entry.isDirectory
                    )
                    .modifier(ArchiveRowActions(
                        model: model,
                        drop: drop,
                        path: entry.path,
                        name: (entry.path as NSString).lastPathComponent,
                        isDirectory: entry.isDirectory
                    ))
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 22)
                .background(
                    MultiDragInstaller(
                        isEnabled: { model.selection.count > 1 },
                        items: { model.dragItems(for: Array(model.selection)) },
                        context: { model.dragContext }
                    )
                )
            } else {
                List(rows, id: \.id, selection: $model.selection) { row in
                    rowBody(
                        name: row.node.name,
                        path: row.node.path,
                        size: row.node.size,
                        packedSize: row.node.packedSize,
                        modified: row.node.modified,
                        isDirectory: row.node.isDirectory,
                        depth: row.depth,
                        node: row.node
                    )
                    .modifier(ArchiveRowActions(
                        model: model,
                        drop: drop,
                        path: row.node.path,
                        name: row.node.name,
                        isDirectory: row.node.isDirectory
                    ))
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 22)
                .background(
                    MultiDragInstaller(
                        isEnabled: { model.selection.count > 1 },
                        items: { model.dragItems(for: Array(model.selection)) },
                        context: { model.dragContext }
                    )
                )
            }
        }
    }

    // MARK: 列头

    private var header: some View {
        HStack(spacing: 0) {
            sortableHeader(.name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortableHeader(.size, alignment: .trailing).frame(width: 86)
            sortableHeader(.modified, alignment: .trailing).frame(width: 132)
            if browser.showPackedColumn {
                sortableHeader(.packedSize, alignment: .trailing).frame(width: 86)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 34)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.03))
    }

    private func sortableHeader(_ key: ArchiveSortKey, alignment: HorizontalAlignment) -> some View {
        Button {
            if model.sortKey == key {
                model.sortAscending.toggle()
            } else {
                model.sortKey = key
                model.sortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(key.title)
                if model.sortKey == key {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(format: L("按%@排序"), key.title))
    }

    // MARK: 行

    private func rowBody(
        name: String,
        path: String,
        size: Int64,
        packedSize: Int64,
        modified: Date?,
        isDirectory: Bool,
        depth: Int = 0,
        node: ArchiveNode? = nil
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                // 缩进用固定宽度占位，不依赖 List 的层级缩进。
                Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
                disclosure(for: node)
                Image(systemName: FileGlyph.symbol(for: name, isDirectory: isDirectory))
                    .font(.system(size: 12))
                    .foregroundStyle(FileGlyph.tint(for: name, isDirectory: isDirectory))
                    .frame(width: 16)
                HighlightedName(text: name, query: model.searchText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(isDirectory ? "—" : ByteFormatter.string(size))
                .frame(width: 86, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(modified.map(DateText.list) ?? "—")
                .frame(width: 132, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if browser.showPackedColumn {
                Text(SizeText.packed(size: size, packed: packedSize, isDirectory: isDirectory))
                    .frame(width: 86, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12))
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(drop.rowTarget == path ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    @ViewBuilder
    private func disclosure(for node: ArchiveNode?) -> some View {
        if let node, node.isDirectory, node.children != nil {
            Button {
                browser.toggle(node.path)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(browser.expanded.contains(node.path) ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }
}

// MARK: - 图标视图

struct ArchiveIconView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: BrowserState

    private var currentPath: String { browser.iconPath.last ?? "" }

    private var nodes: [ArchiveNode] {
        if model.treeNodes.isEmpty {
            // 超大归档不建树：图标视图退回「一层铺开全部条目」，与列表的回退一致。
            return model.entries.map { entry in
                ArchiveNode(
                    path: entry.path,
                    name: (entry.path as NSString).lastPathComponent,
                    size: entry.size,
                    packedSize: entry.packedSize,
                    modified: entry.modified,
                    isDirectory: entry.isDirectory
                )
            }
        }
        return model.childrenIndex[currentPath] ?? []
    }

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 118), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(nodes) { node in
                        cell(node)
                    }
                }
                .padding(16)
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                if !browser.iconPath.isEmpty { browser.iconPath.removeLast() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(browser.iconPath.isEmpty)
            .help(L("返回上一级"))

            Button {
                browser.iconPath = []
            } label: {
                Text(model.archiveURL?.deletingPathExtension().lastPathComponent ?? L("根目录"))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: browser.iconPath.isEmpty ? .semibold : .regular))

            ForEach(Array(browser.iconPath.enumerated()), id: \.offset) { index, path in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Button {
                    browser.iconPath = Array(browser.iconPath.prefix(index + 1))
                } label: {
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: index == browser.iconPath.count - 1 ? .semibold : .regular))
            }
            Spacer(minLength: 0)
            Text(String(format: L("%d 项"), nodes.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func cell(_ node: ArchiveNode) -> some View {
        let selected = model.selection.contains(node.path)
        return VStack(spacing: 4) {
            Image(systemName: FileGlyph.symbol(for: node.name, isDirectory: node.isDirectory))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(FileGlyph.tint(for: node.name, isDirectory: node.isDirectory))
                .frame(height: 40)
            HighlightedName(text: node.name, query: model.searchText, alignment: .center)
                .lineLimit(2)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text(node.isDirectory ? L("文件夹") : ByteFormatter.string(node.size))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(height: 96)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) {
            open(node)
        }
        .onTapGesture {
            model.selection = [node.path]
        }
        .contextMenu {
            if model.canOpenNested(path: node.path, isDirectory: node.isDirectory) {
                Button(L("打开内嵌压缩包")) { model.openNestedArchive(path: node.path) }
                Divider()
            }
            Button("解压到…") { model.extractPaths(model.targets(for: node.path), choosingDestination: true) }
            Button("解压到压缩包所在文件夹") {
                model.extractPaths(model.targets(for: node.path), choosingDestination: false)
            }
            if node.isDirectory {
                Divider()
                Button("进入文件夹") { open(node) }
            }
            Divider()
            Button("重命名…") { model.renameEntry(node.path) }
                .disabled(!model.canEditCurrentArchive)
            Button("从归档中删除") { model.deleteEntries(model.targets(for: node.path)) }
                .disabled(!model.canEditCurrentArchive)
        }
        .help(node.name)
    }

    private func open(_ node: ArchiveNode) {
        if node.isDirectory, node.children != nil {
            browser.iconPath.append(node.path)
            model.selection = []
        } else if model.canOpenNested(path: node.path, isDirectory: node.isDirectory) {
            model.openNestedArchive(path: node.path)
        }
    }
}

// MARK: - 分栏视图

struct ArchiveColumnView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: BrowserState

    /// 每一列要显示的内容：第 0 列是根，第 n 列是第 n-1 列里选中目录的子项。
    private var columns: [(path: String, nodes: [ArchiveNode])] {
        var result: [(String, [ArchiveNode])] = [("", model.childrenIndex[""] ?? [])]
        for folder in browser.columnPath {
            let children = model.childrenIndex[folder] ?? []
            if children.isEmpty { break }
            result.append((folder, children))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    columnView(index: index, folder: column.path, nodes: column.nodes)
                        .frame(width: 218)
                    // 只在列与列之间画分隔线：最后一列右边再画一条，空出来的区域
                    // 看着就像还有一个空列。
                    if index < columns.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func columnView(index: Int, folder: String, nodes: [ArchiveNode]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    row(node, selected: isSelected(node, column: index))
                        .onTapGesture { select(node, column: index) }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private func isSelected(_ node: ArchiveNode, column: Int) -> Bool {
        // 当前列的选中项存在 columnPath[column]；最后一列没有下一层，用 model.selection 兜底。
        if column < browser.columnPath.count {
            return browser.columnPath[column] == node.path
        }
        return model.selection.contains(node.path)
    }

    private func select(_ node: ArchiveNode, column: Int) {
        // 点目录：截断后面的列，追加这一层；点文件：保留父级列，选中它。
        let prefix = Array(browser.columnPath.prefix(column))
        if node.isDirectory, node.children != nil {
            browser.columnPath = prefix + [node.path]
            model.selection = [node.path]
        } else {
            browser.columnPath = prefix
            model.selection = [node.path]
        }
    }

    private func row(_ node: ArchiveNode, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: FileGlyph.symbol(for: node.name, isDirectory: node.isDirectory))
                .font(.system(size: 12))
                .foregroundStyle(FileGlyph.tint(for: node.name, isDirectory: node.isDirectory))
                .frame(width: 16)
            HighlightedName(text: node.name, query: model.searchText)
            Spacer(minLength: 4)
            if node.isDirectory, node.children != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            if model.canOpenNested(path: node.path, isDirectory: node.isDirectory) {
                Button(L("打开内嵌压缩包")) { model.openNestedArchive(path: node.path) }
            }
        }
    }
}

// MARK: - 详情面板

struct DetailPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: BrowserState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let entry = model.detailEntry {
                    entrySection(entry)
                } else {
                    archiveSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 归档概览

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
                Text(model.archiveURL?.lastPathComponent ?? L("未打开归档"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(model.archiveTypeName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if model.isArchiveEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help(L("含加密条目"))
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                DetailRow(label: L("大小"), value: ByteFormatter.string(model.archiveByteSize))
                DetailRow(label: L("解压后"), value: ByteFormatter.string(model.totalUncompressedSize))
                DetailRow(label: L("项目"), value: String(format: L("%d 项 · %d 个文件"), model.entryCount, model.fileCount))
                DetailRow(label: L("加密"), value: model.isArchiveEncrypted ? L("是") : L("否"))
                DetailRow(label: L("修改日期"), value: model.archiveModified.map(DateText.detail) ?? "—")
                DetailRow(
                    label: L("位置"),
                    value: model.isNestedArchive
                        ? String(format: L("内嵌于 %@"), model.nestedTrail)
                        : (model.archiveURL?.deletingLastPathComponent().path ?? "—"),
                    wraps: true
                )
            }

            if !model.treeNodes.isEmpty {
                Divider()
                Button {
                    if browser.expanded.isEmpty {
                        browser.expanded = Set(model.childrenIndex.keys).subtracting([""])
                    } else {
                        browser.expanded = []
                    }
                } label: {
                    Label(
                        browser.expanded.isEmpty ? L("展开全部文件夹") : L("收起全部文件夹"),
                        systemImage: "rectangle.expand.vertical"
                    )
                    .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: 选中项

    private func entrySection(_ entry: ArchiveEntry) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: FileGlyph.symbol(for: name, isDirectory: entry.isDirectory))
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(FileGlyph.tint(for: name, isDirectory: entry.isDirectory))
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(entry.isDirectory ? L("文件夹") : L("文件"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                DetailRow(label: L("大小"), value: ByteFormatter.string(entry.size))
                DetailRow(label: L("压缩后"), value: SizeText.packed(size: entry.size, packed: entry.packedSize, isDirectory: entry.isDirectory))
                if entry.size > 0, entry.packedSize > 0, entry.packedSize <= entry.size {
                    DetailRow(
                        label: L("压缩率"),
                        value: String(format: "%.0f%%", Double(entry.packedSize) / Double(entry.size) * 100)
                    )
                }
                DetailRow(label: L("修改日期"), value: entry.modified.map(DateText.detail) ?? "—")
                DetailRow(label: L("包内路径"), value: entry.path, wraps: true)
            }

            Divider()

            if model.canOpenNested(path: entry.path, isDirectory: entry.isDirectory) {
                Button(L("打开内嵌压缩包")) { model.openNestedArchive(path: entry.path) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Button("解压…") {
                    model.extractPaths(model.targets(for: entry.path), choosingDestination: true)
                }
                .controlSize(.small)
                Button("解压到此处") {
                    model.extractPaths(model.targets(for: entry.path), choosingDestination: false)
                }
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Button("重命名…") { model.renameEntry(entry.path) }
                    .controlSize(.small)
                    .disabled(!model.canEditCurrentArchive)
                Button("从归档中删除") { model.deleteEntries(model.targets(for: entry.path)) }
                    .controlSize(.small)
                    .disabled(!model.canEditCurrentArchive)
            }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var wraps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5))
                .lineLimit(wraps ? 4 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 搜索框

/// 用 `NSSearchField` 而不是 SwiftUI 的 TextField：原生清除按钮、Esc 清空，
/// 而且 `⌘F` 之后可以直接 `makeFirstResponder`，不依赖焦点状态宏。
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.sendsSearchStringImmediately = true
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        let coordinator = context.coordinator
        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>
        var lastFocusToken = 0

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func changed(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        /// Esc 清空搜索，而不是关掉窗口。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                text.wrappedValue = ""
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

// MARK: - 行上的拖拽与右键

/// 列表行上的两个动作：
///   · 拖出去 → 落到访达时解压到那个位置（`NSItemProvider` 文件承诺）；
///   · 把文件拖到这一行 → 加进归档的这个层级（文件夹行进它自己，文件行进它所在那层）。
struct ArchiveRowActions: ViewModifier {
    let model: AppModel
    let drop: DropState
    let path: String
    let name: String
    let isDirectory: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrag {
                model.dragProvider(path: path, name: name, isDirectory: isDirectory)
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.addDroppedFiles(urls, toFolder: targetFolder)
                return true
            } isTargeted: { inside in
                if inside {
                    drop.rowTarget = path
                } else if drop.rowTarget == path {
                    drop.rowTarget = nil
                }
            }
            // 双击：内嵌压缩包直接钻进去看。
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                model.openEntry(path: path, isDirectory: isDirectory)
            })
            .contextMenu {
                if model.canOpenNested(path: path, isDirectory: isDirectory) {
                    Button(L("打开内嵌压缩包")) { model.openNestedArchive(path: path) }
                    Divider()
                }
                Button("解压到…") {
                    model.extractPaths(model.targets(for: path), choosingDestination: true)
                }
                Button("解压到压缩包所在文件夹") {
                    model.extractPaths(model.targets(for: path), choosingDestination: false)
                }
                Divider()
                Button("解压到同级文件夹") {
                    model.extractPathsToNewFolder(model.targets(for: path))
                }
                Divider()
                Button("重命名…") { model.renameEntry(path) }
                    .disabled(!model.canEditCurrentArchive)
                Button("从归档中删除") { model.deleteEntries(model.targets(for: path)) }
                    .disabled(!model.canEditCurrentArchive)
            }
    }

    private var targetFolder: String {
        if isDirectory { return AppModel.normalizeEntryPath(path) }
        return AppModel.normalizeEntryPath((path as NSString).deletingLastPathComponent)
    }
}

// MARK: - 小工具

/// 名字里命中搜索词的那一段描底高亮。
struct HighlightedName: View {
    let text: String
    let query: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var attributed: AttributedString {
        var attr = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return attr }

        var cursor = text.startIndex
        while cursor < text.endIndex,
              let found = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<text.endIndex) {
            if let range = Range(found, in: attr) {
                attr[range].backgroundColor = Color.accentColor.opacity(0.30)
                attr[range].foregroundColor = .primary
            }
            guard found.upperBound > cursor else { break }
            cursor = found.upperBound
        }
        return attr
    }
}

enum FileGlyph {
    static func symbol(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "jar", "war", "cab", "iso", "dmg":
            return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "svg", "bmp":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return "film"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg":
            return "music.note"
        case "swift", "js", "ts", "py", "java", "c", "cpp", "h", "rs", "go", "sh", "json", "yml", "yaml", "xml", "html", "css":
            return "chevron.left.forwardslash.chevron.right"
        case "txt", "md", "rtf", "log", "csv":
            return "doc.text"
        case "app":
            return "app"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    static func tint(for name: String, isDirectory: Bool) -> Color {
        if isDirectory { return .accentColor }
        switch (name as NSString).pathExtension.lowercased() {
        case "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "jar", "war", "cab", "iso", "dmg":
            return .orange
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "svg", "bmp":
            return .teal
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .purple
        case "mp3", "wav", "flac", "aac", "m4a", "ogg":
            return .pink
        default:
            return .secondary
        }
    }
}

enum SizeText {
    /// 压缩后体积。7z 的固实块会把整块的压缩体积记在块内第一个条目上，
    /// 这个数字会大于条目本身，显示出来只会误导，索性不显示。
    static func packed(size: Int64, packed: Int64, isDirectory: Bool) -> String {
        if isDirectory || packed <= 0 { return "—" }
        if size > 0, packed > size { return "—" }
        return ByteFormatter.string(packed)
    }
}

enum DateText {
    private static let listFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func list(_ date: Date) -> String { listFormatter.string(from: date) }
    static func detail(_ date: Date) -> String { detailFormatter.string(from: date) }
}
