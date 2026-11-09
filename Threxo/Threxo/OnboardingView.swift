import SwiftUI
import AppKit
import Combine

// MARK: - 导航状态

/// 首次启动向导的当前页。独立成 ObservableObject，绕开 @State 宏。
final class OnboardingNav: ObservableObject {
    /// 0 = 欢迎页；1...6 = 六个配置步骤（圆点按 1...6 显示）。
    @Published var step: Int = 0

    static let stepCount = 6
}

// MARK: - 窗口

/// 首次启动向导。刻意独立于主窗口：访达右键的静默任务不能因为它弹出窗口。
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    /// 故意不加 `threxo.` 前缀，免得「恢复所有设置」把已完成标记一起清掉。
    private static let completedKey = "ThrexoOnboardingCompleted"

    private var window: NSWindow?
    private let nav = OnboardingNav()

    var isVisible: Bool { window?.isVisible ?? false }

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    /// - Parameters:
    ///   - restart: 从欢迎页重新开始（「重新显示欢迎页面」用）。
    ///   - step: 仅调试截图用，直接落到某一页。
    func show(restart: Bool = false, step: Int? = nil) {
        if restart { nav.step = 0 }
        if let step { nav.step = min(max(step, 0), OnboardingNav.stepCount) }
        if window == nil {
            let hosting = NSHostingView(rootView: OnboardingRootView(nav: nav))
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = L("千梭 首次设置")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.contentView = hosting
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 最后一步「开始使用」：记住完成状态，收起向导，打开主窗口。
    func finish() {
        Self.markCompleted()
        window?.orderOut(nil)
        MainWindowController.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        // 用户直接点了红绿灯：也当作看完向导，不要每次启动都再问一遍。
        Self.markCompleted()
    }
}

// MARK: - 根视图

struct OnboardingRootView: View {
    @ObservedObject var nav: OnboardingNav
    @ObservedObject private var store = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // 欢迎页按原型 1 独占整窗：没有品牌条，也没有底部导航。
            if nav.step > 0 {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(L("千梭"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 6)
            }

            ZStack {
                stepContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if nav.step > 0 {
                Divider()
                navigationBar
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 780, height: 560)
        .background {
            if nav.step == 0 {
                LinearGradient(
                    // 欢迎页的浅粉紫渐变在深色模式下配白字看不清，按外观换一套。
                    colors: colorScheme == .dark
                        ? [Color(red: 0.19, green: 0.12, blue: 0.18),
                           Color(red: 0.11, green: 0.12, blue: 0.21)]
                        : [Color(red: 1.0, green: 0.95, blue: 0.95),
                           Color(red: 0.93, green: 0.94, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            } else {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch nav.step {
        case 0: WelcomeStep(start: { nav.step = 1 },
                            skip: { OnboardingWindowController.shared.finish() })
        case 1: MiniStep(store: store)
        case 2: FormatsStep()
        case 3: FinderStep(store: store)
        case 4: AppearanceStep(store: store)
        case 5: FreeStep(store: store)
        default: ReadyStep(store: store)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            if nav.step > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { nav.step -= 1 }
                } label: {
                    Label(L("返回"), systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)

                Button(L("跳过设置")) { OnboardingWindowController.shared.finish() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else {
                Spacer().frame(width: 60)
            }

            Spacer()

            if nav.step > 0 {
                HStack(spacing: 7) {
                    ForEach(1...OnboardingNav.stepCount, id: \.self) { index in
                        Circle()
                            .fill(index == nav.step ? Color.accentColor : Color.primary.opacity(0.18))
                            .frame(width: 7, height: 7)
                    }
                }
            }

            Spacer()

            Button {
                if nav.step >= OnboardingNav.stepCount {
                    OnboardingWindowController.shared.finish()
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { nav.step += 1 }
                }
            } label: {
                Text(nav.step >= OnboardingNav.stepCount ? L("开始使用") : L("下一步"))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - 步骤 0：欢迎

private struct WelcomeStep: View {
    let start: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text(L("欢迎使用千梭"))
                .font(.system(size: 30, weight: .bold))
            Text(L("Mac 解压缩工具，所有功能免费"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button {
                start()
            } label: {
                Text(L("开始设置")).frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)

            Button(L("跳过设置，直接开始")) { skip() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 步骤 1：Mini

private struct MiniStep: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        StepLayout(title: L("千梭 Mini"), subtitle: L("打开压缩包时用一个更轻的窗口，看完就走")) {
            MiniIllustration()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

            StepCard {
                StepRow(L("默认用 Mini 打开压缩包"), subtitle: L("从访达打开压缩包时优先使用精简窗口")) {
                    Toggle("", isOn: $store.miniDefaultOpen).toggleStyle(.switch).labelsHidden()
                }
            }
            Text(L("Mini 窗口形态还在开发，这个开关会一直记住，上线后直接生效。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// 用 SwiftUI 画一个精简窗口示意，不依赖图片资源。
private struct MiniIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("照片集.zip").font(.system(size: 12, weight: .semibold))
                    Text("ZIP 压缩包 · 26 个项目").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("千梭 Mini").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            VStack(spacing: 0) {
                ForEach(["IMG_0079.jpeg", "IMG_0667.jpeg", "IMG_0927.jpeg", "IMG_1207.jpeg"], id: \.self) { name in
                    HStack {
                        Image(systemName: "photo").font(.system(size: 9))
                        Text(name).font(.system(size: 10))
                        Spacer()
                        Text("2.1 MB").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(name == "IMG_0927.jpeg" ? Color.accentColor.opacity(0.18) : Color.clear)
                }
            }
            Divider()
            HStack(spacing: 8) {
                ForEach(["xmark", "plus", "arrow.up.arrow.down"], id: \.self) { icon in
                    Image(systemName: icon).font(.system(size: 8))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Text(L("解压")).font(.system(size: 9))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                Text(L("全部解压")).font(.system(size: 9))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .padding(10)
        }
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10)))
    }
}

// MARK: - 步骤 2：格式关联

private struct FormatsStep: View {
    @StateObject private var state = FormatBindingState()

    private var common: [SettingsStore.FormatBinding] {
        state.bindings.filter { $0.group == SettingsStore.formatGroups[0] }
    }

    private var recommendedTitle: String {
        state.remainingRecommended == 0
            ? L("常用格式已全部关联")
            : String(format: L("关联下一个格式（还剩 %d 项）"), state.remainingRecommended)
    }

    var body: some View {
        StepLayout(title: L("关联文件格式"), subtitle: L("不确定该选哪些？点下面的按钮逐个关联即可")) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("双击压缩包时，用千梭打开。"))
                        .font(.system(size: 13))
                    Text(L("关掉的那些仍由系统或其他应用打开，随时可以在设置里改回来。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(recommendedTitle) { state.associateNext() }
                        .controlSize(.small)
                        .disabled(state.remainingRecommended == 0 || !state.pending.isEmpty)
                    Text(L("点一次只改一个格式。macOS 会弹一次确认框，选「使用千梭」；确认完再点下一个。"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = state.message {
                        Text(message).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
                .frame(width: 220, alignment: .leading)

                StepCard {
                    ForEach(Array(common.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 12) }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 11.5))
                                Text(item.extensions).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            if item.uti == nil {
                                Text(L("系统未登记")).font(.system(size: 9)).foregroundStyle(.secondary)
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { item.isDefault },
                                    set: { state.set(item, enabled: $0) }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                                .disabled(state.pending.contains(item.id))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
                .frame(width: 300)
            }
        }
        .onAppear { state.refresh() }
    }
}

// MARK: - 步骤 3：访达右键菜单

private struct FinderStep: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var extensionState = FinderExtensionState()

    var body: some View {
        StepLayout(title: L("开启访达菜单项"), subtitle: L("在右键菜单里直接压缩和解压，不用先打开千梭")) {
            HStack(alignment: .top, spacing: 20) {
                FinderMenuIllustration()
                    .frame(width: 250)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.primary.opacity(0.10)).frame(width: 18, height: 18)
                            .overlay(Text("1").font(.system(size: 10)))
                        Text(L("点下面的按钮打开系统设置"))
                            .font(.system(size: 12))
                    }
                    HStack(spacing: 6) {
                        Circle().fill(Color.primary.opacity(0.10)).frame(width: 18, height: 18)
                            .overlay(Text("2").font(.system(size: 10)))
                        Text(L("在「登录项与扩展 → 访达」里勾上千梭"))
                            .font(.system(size: 12))
                    }
                    Button(L("打开系统设置")) { AppModel.shared.openExtensionSettings() }
                        .controlSize(.small)
                        .padding(.top, 2)
                    Text(extensionState.enabled
                         ? L("已启用，右键菜单随时可用")
                         : L("还没启用，可以稍后再设，不影响现在使用"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(extensionState.enabled ? Color.green : Color.secondary)
                    Button(L("刷新状态")) { extensionState.refresh() }
                        .controlSize(.small)
                }
                .frame(width: 260, alignment: .leading)
            }

            StepCard {
                StepRow(L("在移动存储中开启右键菜单"),
                        subtitle: L("外接硬盘、U 盘里的文件也提供右键菜单")) {
                    Toggle("", isOn: $store.finderMenuOnExternalVolumes)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onAppear { extensionState.refresh() }
    }
}

private struct FinderMenuIllustration: View {
    private let items = [
        ("用千梭解压", "arrow.down.circle"),
        ("用千梭解压到…", "folder"),
        ("用千梭压缩「照片集」", "archivebox"),
        ("用千梭压缩为…", "square.and.pencil"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index == 2 { Divider().padding(.vertical, 3) }
                HStack(spacing: 8) {
                    Image(systemName: item.1).font(.system(size: 10))
                        .frame(width: 14)
                    Text(L(item.0)).font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.10)))
    }
}

// MARK: - 步骤 4：外观与语言

private struct AppearanceStep: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        StepLayout(title: L("外观与语言"), subtitle: L("这几项以后都能在设置里改")) {
            StepCard {
                StepRow(L("外观"), subtitle: L("浅色、深色或跟随系统")) {
                    Picker("", selection: $store.appearance) {
                        ForEach(SettingsStore.AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                Divider().padding(.leading, 12)
                StepRow(L("应用语言"), subtitle: L("改完重启千梭生效")) {
                    Picker("", selection: $store.language) {
                        ForEach(SettingsStore.LanguageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                Divider().padding(.leading, 12)
                StepRow(L("默认浏览方式"), subtitle: L("打开压缩包后列表怎么排")) {
                    Picker("", selection: $store.browseMode) {
                        ForEach(SettingsStore.BrowseMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            .frame(maxWidth: 520)
        }
    }
}

// MARK: - 步骤 5：全部免费

private struct FreeStep: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var options = CompressionOptions.shared

    var body: some View {
        StepLayout(title: L("所有功能，全部免费"), subtitle: L("没有试用期，没有功能门禁，也不用登录")) {
            HStack(spacing: 10) {
                FreeBadge(icon: "square.and.pencil", title: L("包内编辑"))
                FreeBadge(icon: "externaldrive", title: L("分卷压缩"))
                FreeBadge(icon: "key", title: L("密码本"))
                FreeBadge(icon: "link", title: L("格式关联"))
            }

            StepCard {
                StepRow(L("默认压缩用途"), subtitle: L("创建压缩包时先替你把格式和强度拨好")) {
                    Picker("", selection: Binding(
                        get: { options.matchingPurpose?.rawValue ?? "custom" },
                        set: { raw in
                            if let purpose = CompressionPurpose(rawValue: raw) {
                                options.apply(purpose)
                            }
                        }
                    )) {
                        Text(L("自定义")).tag("custom")
                        ForEach(CompressionPurpose.allCases) { purpose in
                            Text(purpose.title).tag(purpose.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                Divider().padding(.leading, 12)
                StepRow(L("双击快速解压"), subtitle: L("双击压缩包直接解到同级目录，跳过浏览")) {
                    Toggle("", isOn: $store.quickExtractOnDoubleClick)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            .frame(maxWidth: 520)
        }
    }
}

private struct FreeBadge: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 11))
        }
        .frame(width: 104, height: 72)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.10)))
    }
}

// MARK: - 步骤 6：一切就绪

private struct ReadyStep: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
            Text(L("一切就绪"))
                .font(.system(size: 30, weight: .bold))
            Text(L("现在可以拖个文件进来，或者去访达里右键试试。"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            StepCard {
                StepRow(L("开机自动启动千梭"), subtitle: store.loginItemError ?? L("登录后自动运行，访达右键随即可用")) {
                    Toggle("", isOn: $store.launchAtLogin).toggleStyle(.switch).labelsHidden()
                }
            }
            .frame(width: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 通用骨架

private struct StepLayout<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StepCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct StepRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
