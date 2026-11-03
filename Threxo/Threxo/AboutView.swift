import SwiftUI
import AppKit
import Combine

/// 关于页的三个分页。
enum AboutPage: String, CaseIterable, Identifiable {
    case about, notices, license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .about: return L("关于")
        case .notices: return L("第三方组件")
        case .license: return L("7-Zip 许可")
        }
    }
}

/// 用 `ObservableObject` 存分页状态：命令行构建环境里 `@State` 依赖的
/// swift-plugin-server 会被沙箱拦掉，宏展开失败（见 ContentView 的 HeaderState）。
private final class AboutState: ObservableObject {
    @Published var page: AboutPage = .about
}

/// App 内的关于与许可页。
///
/// 存在的理由是合规：7-Zip 以 LGPL 分发，随包带许可文本还不够，
/// 用户得能在 App 里点到它（GAP-08）。顺带把版本、构建号和仓库地址放这儿。
struct AboutView: View {
    @StateObject private var ui = AboutState()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $ui.page) {
                ForEach(AboutPage.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                Group {
                    switch ui.page {
                    case .about: aboutSection
                    case .notices: textSection(Self.bundledText("THIRD_PARTY_NOTICES", "md"))
                    case .license: textSection(Self.bundledText("7zip-License", "txt"))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 580, height: 500)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("千梭"))
                    .font(.title2.bold())
                Text(String(format: L("版本 %@（%@）· 7-Zip 26.04 引擎"), version, build))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("解压、压缩、在压缩包内直接看文件。全部处理都在本机完成，不上传任何内容，也不联网。"))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                row(L("压缩引擎"), L("7-Zip 26.04，以独立进程调用，未做任何修改"))
                row(L("支持解压"), "7z · zip · rar · tar · gz · bz2 · xz · zst · cab · iso · wim · jar · war")
                row(L("支持创建"), "7z · zip · tar · gz · bz2 · xz")
                row(L("要求"), L("macOS 14.0 或更高，Apple 芯片与 Intel"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("链接"))
                    .font(.callout.weight(.semibold))
                Link("github.com/qujunxian/Threxo",
                     destination: URL(string: "https://github.com/qujunxian/Threxo")!)
                    .font(.callout)
                Link("7-zip.org",
                     destination: URL(string: "https://www.7-zip.org/")!)
                    .font(.callout)
            }

            Text(L("© 2026 曲俊现。本程序按 MIT 许可发布；内置的 7-Zip 遵循其自身许可，见「第三方组件」与「7-Zip 许可」。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func textSection(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private static func bundledText(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return L("许可文件缺失。请从发布页重新下载完整安装包。")
        }
        return text
    }
}

/// 独立的关于窗口。不并入主窗口，避免「右键静默任务」因为看许可而被判定成有界面。
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = L("关于千梭")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
