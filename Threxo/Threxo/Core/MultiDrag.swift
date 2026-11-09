import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 多选拖出到访达。
///
/// SwiftUI 的 `onDrag` 一次只能交出一个 `NSItemProvider`，选中 3 行拖到桌面
/// 只会落地 1 个。AppKit 的拖拽会话没有这个限制：每个选中项挂一个
/// `NSFilePromiseProvider`，访达就会收到 3 份独立的文件承诺，落到桌面就是 3 个条目。
///
/// 承诺仍然是「落下时才解」：拖拽过程中只登记，不提前把内容解到临时目录。
enum MultiDrag {
    struct Item {
        let path: String
        let name: String
        let isDirectory: Bool
    }

    /// 一项拖拽的上下文。压缩包地址、密码、7zz 路径在拖拽开始时拍下来，
    /// 之后切归档也不影响已经在空中的这一批。
    struct Context {
        let archive: URL?
        let password: String?
        let executable: URL
    }

    /// 收集 PromiseWriter 的强引用：`NSFilePromiseProvider.delegate` 是弱引用，
    /// 拖拽会话期间没人持有就会提前释放，落盘时回调到空对象。
    private static var writers: [ObjectIdentifier: PromiseWriter] = [:]

    static func begin(
        items: [Item],
        context: Context,
        event: NSEvent,
        in view: NSView
    ) {
        guard !items.isEmpty, let window = view.window else { return }
        let origin = view.convert(event.locationInWindow, from: nil)

        var draggingItems: [NSDraggingItem] = []
        for (index, item) in items.enumerated() {
            let writer = PromiseWriter(item: item, context: context)
            writers[ObjectIdentifier(writer)] = writer

            let provider = NSFilePromiseProvider(
                fileType: item.isDirectory ? UTType.folder.identifier : UTType.data.identifier,
                delegate: writer
            )
            writer.provider = provider

            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            // 多个条目稍微错开一点，拖动时能看出是「一摞」而不是一个。
            let offset = CGFloat(index) * 12
            let frame = NSRect(
                x: origin.x - 16 + offset,
                y: origin.y - 16 - offset,
                width: 32,
                height: 32
            )
            draggingItem.setDraggingFrame(frame, contents: icon(for: item))
            draggingItems.append(draggingItem)
        }

        window.makeKey()
        view.beginDraggingSession(with: draggingItems, event: event, source: DragSource.shared)
    }

    static func release(_ writer: PromiseWriter) {
        writers.removeValue(forKey: ObjectIdentifier(writer))
    }

    /// 拖动时鼠标旁边的小图：文件夹用系统文件夹图标，文件按扩展名取。
    private static func icon(for item: Item) -> NSImage {
        if item.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    /// 拖拽源：只允许拷贝，拖出去的东西不会从归档里消失。
    final class DragSource: NSObject, NSDraggingSource {
        static let shared = DragSource()

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }
    }

    /// 单项承诺的落盘实现：访达要文件时才解压，解完搬过去。
    final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
        let item: Item
        let context: Context
        weak var provider: NSFilePromiseProvider?

        init(item: Item, context: Context) {
            self.item = item
            self.context = context
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            fileNameForType fileType: String
        ) -> String {
            item.name
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { DispatchQueue.main.async { MultiDrag.release(self) } }
                do {
                    guard let archive = context.archive else {
                        throw ArchiveExport.ExportError.noArchive
                    }
                    let materialized = try ArchiveExport.materialize(
                        archive: archive,
                        items: [item.path],
                        pathInArchive: item.path,
                        password: context.password,
                        executable: context.executable
                    )
                    let fm = FileManager.default
                    // 访达有时会先建一个占位文件/目录，直接搬会撞名。
                    if fm.fileExists(atPath: url.path) {
                        try? fm.removeItem(at: url)
                    }
                    do {
                        try fm.moveItem(at: materialized, to: url)
                    } catch {
                        // 跨卷（拖到外接盘）时 move 会失败，退回拷贝。
                        try fm.copyItem(at: materialized, to: url)
                        try? fm.removeItem(at: materialized)
                    }
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }
}

// MARK: - 触发多选拖拽

/// 透明背景视图 + 本地事件监听。
///
/// 只做一件事：**多选**状态下把拖动事件接过来，改用 AppKit 的拖拽会话；
/// 其余情况原样放行，单击、框选、单选拖拽都还是 SwiftUI 自己处理。
/// 视图本身 `hitTest` 恒返回 nil，不会挡住任何点击。
struct MultiDragInstaller: NSViewRepresentable {
    let isEnabled: () -> Bool
    let items: () -> [MultiDrag.Item]
    let context: () -> MultiDrag.Context

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.host = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.host = nsView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, items: items, context: context)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var host: NSView?
        private let isEnabled: () -> Bool
        private let items: () -> [MultiDrag.Item]
        private let context: () -> MultiDrag.Context

        private var monitors: [Any] = []
        private var downPoint: NSPoint?
        private var downWasMulti = false
        private var dragStarted = false

        init(
            isEnabled: @escaping () -> Bool,
            items: @escaping () -> [MultiDrag.Item],
            context: @escaping () -> MultiDrag.Context
        ) {
            self.isEnabled = isEnabled
            self.items = items
            self.context = context
        }

        func install() {
            guard monitors.isEmpty else { return }
            if let mouseDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                self?.noteMouseDown(event)
                return event
            }) {
                monitors.append(mouseDown)
            }
            if let dragged = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] event in
                guard let self else { return event }
                return self.handleDrag(event) ? nil : event
            }) {
                monitors.append(dragged)
            }
        }

        func uninstall() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }

        private func noteMouseDown(_ event: NSEvent) {
            downPoint = nil
            downWasMulti = false
            dragStarted = false
            guard let host, let window = host.window, event.window === window else { return }
            // 只认落在列表区域里的按下：标题栏、搜索框、滚动条都不该被接管。
            let point = host.convert(event.locationInWindow, from: nil)
            guard host.bounds.contains(point) else { return }
            downPoint = event.locationInWindow
            downWasMulti = isEnabled()
        }

        /// - Returns: 是否已经接管（true 表示吞掉这个事件，SwiftUI 的 onDrag 不会启动）。
        private func handleDrag(_ event: NSEvent) -> Bool {
            guard downWasMulti, !dragStarted,
                  let host, let window = host.window, event.window === window,
                  let start = downPoint else { return false }

            let point = event.locationInWindow
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return false }

            let batch = items()
            guard batch.count > 1, let content = window.contentView else { return false }

            dragStarted = true
            downPoint = nil
            MultiDrag.begin(items: batch, context: context(), event: event, in: content)
            // 会话结束后复位，下一次按下重新判断。
            DispatchQueue.main.async { [weak self] in self?.dragStarted = false }
            return true
        }
    }
}
