import SwiftUI
import AppKit
import FinderSync

/// 处理「双击归档」「拖到 Dock 图标」「用千梭打开」这些系统级打开事件。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async {
            AppModel.shared.receiveOpenFiles(urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }
}

@main struct ThrexoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        // Finder 扩展必须由容器 App 设置监视目录，pkd 才会真正激活扩展。
        // 设在扩展的 init 里不保证持久化，这里做权威设置（MVP 监视整个磁盘）。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    var body: some Scene {
        WindowGroup("千梭") {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开归档…") { model.openArchive() }
                    .keyboardShortcut("o")
                Button("压缩…") { model.compress() }
                    .keyboardShortcut("n")
                Divider()
                Button("解压") { model.extractAll() }
                    .keyboardShortcut("e")
                    .disabled(model.isBusy || model.entries.isEmpty || model.hasSelection)
                Button("解压所选 \(model.selection.count) 项") { model.extractSelected() }
                    .keyboardShortcut("e")
                    .disabled(model.isBusy || !model.hasSelection)
                Button("解压到…") { model.extractAllChoosingDestination() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.entries.isEmpty)
            }
        }
    }
}
