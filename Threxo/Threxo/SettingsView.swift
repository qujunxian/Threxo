import SwiftUI
import AppKit
import Combine
import LocalAuthentication
import FinderSync

// MARK: - 页面与导航

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case compress
    case extract
    case vault
    case mini
    case formats
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("通用")
        case .compress: return L("压缩")
        case .extract: return L("解压")
        case .vault: return L("密码本")
        case .mini: return L("Mini")
        case .formats: return L("格式关联")
        case .advanced: return L("高级")
        case .about: return L("关于")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .compress: return "archivebox"
        case .extract: return "arrow.down.doc"
        case .vault: return "key"
        case .mini: return "macwindow"
        case .formats: return "link"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

/// 侧边栏选中项。独立成 ObservableObject，避免在 View 里使用 @State 宏。
final class SettingsNav: ObservableObject {
    @Published var page: SettingsPage

    init(page: SettingsPage = .general) {
        self.page = page
    }
}

// MARK: - 设置窗口

/// 自己建窗口，不走 SwiftUI 的 `Settings` 场景。
/// 场景版窗口尺寸被内容牵着走，`showSettingsWindow:` 这个私有 selector 在新系统上也不保证能唤起。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(page: SettingsPage = .general) {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsRootView(initialPage: page))
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = L("千梭设置")
            panel.contentView = hosting
            panel.minSize = NSSize(width: 820, height: 560)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.setFrameAutosaveName("ThrexoSettingsWindow")
            if !panel.setFrameUsingName("ThrexoSettingsWindow") {
                panel.center()
            }
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    @StateObject private var store = SettingsStore.shared
    @StateObject private var options = CompressionOptions.shared
    @StateObject private var nav: SettingsNav

    init(initialPage: SettingsPage = .general) {
        _nav = StateObject(wrappedValue: SettingsNav(page: initialPage))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(nav.page.title)
                        .font(.system(size: 21, weight: .bold))
                    page
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 880, height: 620)
        .onAppear { store.applyAppearance() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(L("千梭"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(SettingsPage.allCases) { item in
                Button {
                    nav.page = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 12))
                            .frame(width: 16)
                        Text(item.title)
                            .font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(nav.page == item ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(nav.page == item ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 188)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var page: some View {
        switch nav.page {
        case .general: GeneralSettingsPage(store: store)
        case .compress: CompressSettingsPage(store: store, options: options)
        case .extract: ExtractSettingsPage(store: store)
        case .vault: VaultSettingsPage(store: store)
        case .mini: MiniSettingsPage(store: store)
        case .formats: FormatSettingsPage(store: store)
        case .advanced: AdvancedSettingsPage(store: store)
        case .about: AboutSettingsPage(store: store)
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var extensionState = FinderExtensionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(L("启动")) {
                Row(L("开机自动启动千梭"), subtitle: store.loginItemError ?? L("登录后自动运行，访达右键随即可用")) {
                    Toggle("", isOn: $store.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Card(L("外观")) {
                HStack(spacing: 12) {
                    ForEach(SettingsStore.AppearanceMode.allCases) { mode in
                        AppearanceOption(mode: mode, selected: store.appearance == mode) {
                            store.appearance = mode
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }

            Card(L("浏览")) {
                Row(L("默认浏览方式")) {
                    Picker("", selection: $store.browseMode) {
                        ForEach(SettingsStore.BrowseMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                Divider().padding(.leading, 14)
                Row(L("显示辅助项目"), subtitle: L("显示 __MACOSX、.DS_Store 这类通常隐藏的系统辅助文件")) {
                    Toggle("", isOn: $store.showAuxiliaryItems)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Card(L("语言")) {
                Row(L("应用语言"), subtitle: L("改完重启千梭生效")) {
                    Picker("", selection: $store.language) {
                        ForEach(SettingsStore.LanguageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Card(L("密码输入")) {
                Row(L("默认显示密码"), subtitle: L("密码框直接显示明文，可随时切换回隐藏")) {
                    Toggle("", isOn: $store.showPasswordByDefault)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Card(L("处理器使用")) {
                Row(
                    L("最大可用核心数"),
                    subtitle: String(format: L("本机 %d 核，默认用满；调低可给别的程序留点余力"),
                                     SettingsStore.coreCount)
                ) {
                    Picker("", selection: $store.maxThreads) {
                        ForEach(SettingsStore.coreOptions, id: \.self) { count in
                            Text(String(format: L("%d 核"), count)).tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            Card(L("欢迎页面")) {
                Row(L("重新显示欢迎页面"), subtitle: L("重新走一遍首次设置向导，不会重置已有设置")) {
                    Button(L("重新显示")) {
                        OnboardingWindowController.shared.show(restart: true)
                    }
                    .controlSize(.small)
                }
            }

            Card(L("访达扩展")) {
                Row(L("在移动存储中开启右键菜单"), subtitle: L("把外接硬盘、U 盘也纳入访达扩展的监视范围")) {
                    Toggle("", isOn: $store.finderMenuOnExternalVolumes)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(
                    extensionState.enabled ? L("右键菜单已启用") : L("右键菜单未启用"),
                    subtitle: extensionState.enabled
                        ? L("在访达里右键压缩包或文件即可压缩解压，不需要打开千梭")
                        : L("到系统设置的登录项与扩展里勾选千梭，或点右侧按钮重新加载")
                ) {
                    HStack(spacing: 8) {
                        Button(L("重新加载")) {
                            store.repairFinderExtension(extensionID: FinderExtensionState.extensionID)
                            extensionState.refresh()
                        }
                        Button(L("打开设置")) {
                            AppModel.shared.openExtensionSettings()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { extensionState.refresh() }
    }
}

private struct AppearanceOption: View {
    let mode: SettingsStore.AppearanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(previewBackground)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2 : 1)
                    HStack(spacing: 3) {
                        Circle().fill(Color.red.opacity(0.6)).frame(width: 5, height: 5)
                        Circle().fill(Color.yellow.opacity(0.6)).frame(width: 5, height: 5)
                        Circle().fill(Color.green.opacity(0.6)).frame(width: 5, height: 5)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: 96, height: 58)

                HStack(spacing: 4) {
                    Text(mode.title)
                        .font(.system(size: 11.5))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var previewBackground: LinearGradient {
        switch mode {
        case .light:
            return LinearGradient(colors: [Color.white, Color(white: 0.93)], startPoint: .top, endPoint: .bottom)
        case .dark:
            return LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
        case .system:
            return LinearGradient(colors: [Color.white, Color(white: 0.2)], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// 访达扩展开关状态。读一次要几十毫秒，放在独立对象里避免每次重绘都读。
final class FinderExtensionState: ObservableObject {
    static let extensionID = "com.qujunxian.Threxo.Finder"

    @Published var enabled = false

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            process.arguments = ["-m", "-i", Self.extensionID]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let isEnabled = output.contains("+")
            DispatchQueue.main.async { self?.enabled = isEnabled }
        }
    }
}

// MARK: - 压缩

private struct CompressSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var options: CompressionOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(L("默认格式与强度")) {
                Row(L("压缩格式"), subtitle: L("在访达右键压缩时使用这个格式")) {
                    Picker("", selection: $options.format) {
                        ForEach(ArchiveFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("压缩强度")).font(.system(size: 12.5))
                        Spacer()
                        Text(options.level.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(options.level.rawValue) },
                            set: { options.level = CompressionLevel(rawValue: Int($0.rounded())) ?? .normal }
                        ),
                        in: 0...4,
                        step: 1
                    )
                    .disabled(!options.format.supportsLevel)
                    HStack {
                        Text(L("更快")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Text(L("更小")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .opacity(options.format.supportsLevel ? 1 : 0.5)
            }

            Card(L("默认用途")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(CompressionPurpose.allCases) { purpose in
                            Button {
                                options.apply(purpose)
                            } label: {
                                Text(purpose.title)
                                    .font(.system(size: 10.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(options.matchingPurpose == purpose
                                                  ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(options.matchingPurpose == purpose
                                                          ? Color.accentColor : Color.primary.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Text(L("用途只是一组格式与强度的预设，改了下面任何一项就会显示成「自定义」。"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card(L("分卷压缩")) {
                Row(L("默认创建分卷压缩包"), subtitle: L("只对 ZIP 与 7Z 有效，访达右键压缩始终不分卷")) {
                    Toggle("", isOn: Binding(
                        get: { options.volumeSize != .none },
                        set: { options.volumeSize = $0 ? .mb100 : .none }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("每卷大小")) {
                    Picker("", selection: $options.volumeSize) {
                        ForEach(VolumeSize.allCases.filter { $0 != .none }) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(options.volumeSize == .none)
                }
            }

            Card(L("内容")) {
                Row(L("排除 macOS 辅助文件"), subtitle: L("不打包 __MACOSX、.DS_Store、._* 这类文件")) {
                    Toggle("", isOn: $options.excludeMacResources)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("压缩后校验归档"), subtitle: L("生成后完整读一遍校验，会多花一倍 IO 时间")) {
                    Toggle("", isOn: $options.verifyAfterCompress)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("压缩后把源文件移入废纸篓"), subtitle: L("只在压缩成功后执行，默认关闭")) {
                    Toggle("", isOn: $options.deleteSourceAfterCompress)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button(L("恢复压缩默认值")) {
                    options.resetToDefaults()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 解压

private struct ExtractSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(L("打开压缩包")) {
                Row(L("双击时快速解压"), subtitle: L("双击压缩包直接解到所在文件夹，跳过浏览步骤")) {
                    Toggle("", isOn: $store.quickExtractOnDoubleClick)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Card(L("解压位置与重名")) {
                Row(L("默认解压到")) {
                    Picker("", selection: $store.extractionTarget) {
                        ForEach(SettingsStore.ExtractionTarget.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Divider().padding(.leading, 14)
                Row(L("目标里已有同名文件"), subtitle: store.conflictPolicy == .overwrite ? L("会覆盖原文件，覆盖前会再确认一次") : nil) {
                    Picker("", selection: $store.conflictPolicy) {
                        ForEach(SettingsStore.ConflictPolicy.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            Card(L("解压完成后")) {
                Row(L("在访达里选中解压结果")) {
                    Toggle("", isOn: $store.revealAfterExtract)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("关闭压缩包窗口")) {
                    Toggle("", isOn: $store.closeAfterExtract)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("如何处理压缩包"), subtitle: L("解压成功后才会执行")) {
                    Picker("", selection: $store.archiveHandling) {
                        ForEach(SettingsStore.ArchiveHandling.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Card(L("内容过滤")) {
                Row(L("自动排除系统辅助文件"), subtitle: L("过滤 macOS 与 Windows 生成的 __MACOSX、.DS_Store、Thumbs.db")) {
                    Toggle("", isOn: $store.filterSystemAux)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("自动过滤 DMG 安装辅助文件"), subtitle: L("跳过 .background 布局文件与 Applications 替身")) {
                    Toggle("", isOn: $store.filterDMGAux)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Text(L("明确选中的条目、用户自己的隐藏文件和应用包内容不会被过滤。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 密码本

/// 页面状态单独放 ObservableObject：这个工程里 @State 宏在命令行构建时会被拦。
final class VaultPageState: ObservableObject {
    @Published var locked = false
    @Published var revealed: Set<String> = []
    @Published var authError: String?
}

private struct VaultSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var vault = PasswordVault.shared
    @StateObject private var state = VaultPageState()

    private var needsUnlock: Bool { store.vaultRequireAuth && state.locked }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(L("自动保存")) {
                Row(L("自动保存到密码本"), subtitle: L("成功解压或创建加密包后，记下这次用的密码")) {
                    Toggle("", isOn: $store.vaultAutoSave).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("自动使用密码本解锁"), subtitle: L("打开加密包时先试一遍已保存的密码，试不出来再问")) {
                    Toggle("", isOn: $store.vaultAutoTry).toggleStyle(.switch).labelsHidden()
                }
            }

            Card(L("安全")) {
                Row(L("查看密码本需要认证"), subtitle: L("用 Touch ID 或系统密码解锁后才能看到明文")) {
                    Toggle("", isOn: $store.vaultRequireAuth).toggleStyle(.switch).labelsHidden()
                }
            }

            Card(L("已保存的密码")) {
                if needsUnlock {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text(L("密码本已锁定")).font(.system(size: 12))
                        Spacer()
                        Button(L("解锁…")) { unlock() }.controlSize(.small)
                    }
                    .padding(14)
                    if let error = state.authError {
                        Text(error).font(.system(size: 10.5)).foregroundStyle(.red)
                            .padding(.horizontal, 14).padding(.bottom, 10)
                    }
                } else {
                    if vault.entries.isEmpty {
                        Row(L("还没有保存的密码"),
                            subtitle: L("手动加一条，或者打开上面的自动保存")) {
                            Button(L("添加密码…")) { addEntry() }.controlSize(.small)
                        }
                    } else {
                        ForEach(Array(vault.entries.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 14) }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 12.5))
                                    Text(item.note.isEmpty ? L("按归档名匹配") : item.note)
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(state.revealed.contains(item.name) ? item.password : "••••••••")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Button(state.revealed.contains(item.name) ? L("隐藏") : L("显示")) {
                                    if state.revealed.contains(item.name) {
                                        state.revealed.remove(item.name)
                                    } else {
                                        state.revealed.insert(item.name)
                                    }
                                }
                                .controlSize(.small)
                                Button(L("删除")) { removeEntry(item.name) }
                                    .controlSize(.small)
                                    .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        Divider().padding(.leading, 14)
                        HStack {
                            Spacer()
                            Button(L("添加密码…")) { addEntry() }.controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }

            if let error = vault.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }

            Text(L("密码存在系统钥匙串里，不写进配置文件；卸载 App 后可以在「钥匙串访问」里删掉。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            vault.reload()
            if store.vaultRequireAuth { state.locked = true }
        }
        .onChange(of: store.vaultRequireAuth) { enabled in
            state.locked = enabled
            state.revealed = []
        }
    }

    private func unlock() {
        state.authError = nil
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            state.authError = error?.localizedDescription ?? L("这台 Mac 不支持解锁认证")
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: L("解锁千梭密码本")) { ok, failure in
            DispatchQueue.main.async {
                if ok {
                    state.locked = false
                } else {
                    state.authError = failure?.localizedDescription ?? L("认证没通过")
                }
            }
        }
    }

    private func addEntry() {
        let alert = NSAlert()
        alert.messageText = L("添加密码")
        alert.informativeText = L("名字可以写归档文件名，也可以写个好记的备注。")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("取消"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 96))
        let name = NSTextField(frame: NSRect(x: 0, y: 72, width: 280, height: 24))
        name.placeholderString = L("归档名，例如 报告.zip")
        let passwordField: NSTextField = SettingsStore.shared.showPasswordByDefault
            ? NSTextField(frame: NSRect(x: 0, y: 40, width: 280, height: 24))
            : NSSecureTextField(frame: NSRect(x: 0, y: 40, width: 280, height: 24))
        passwordField.placeholderString = L("密码")
        let note = NSTextField(frame: NSRect(x: 0, y: 8, width: 280, height: 24))
        note.placeholderString = L("备注（可留空）")
        container.addSubview(name)
        container.addSubview(passwordField)
        container.addSubview(note)
        alert.accessoryView = container
        alert.window.initialFirstResponder = name
        alert.window.level = .floating

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !passwordField.stringValue.isEmpty else { return }
        vault.upsert(name: trimmed, password: passwordField.stringValue,
                     note: note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func removeEntry(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("删掉「%@」这条密码？"), name)
        alert.informativeText = L("只是从密码本移除，不会改动压缩包。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("删除"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        state.revealed.remove(name)
        vault.remove(name: name)
    }
}

// MARK: - Mini

private struct MiniSettingsPage: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(L("打开方式与外观")) {
                Row(L("默认用 Mini 打开"), subtitle: L("从访达打开压缩包时优先用精简窗口")) {
                    Toggle("", isOn: $store.miniDefaultOpen).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("使用毛玻璃材质"), subtitle: L("关掉后用不透明的普通窗口背景")) {
                    Toggle("", isOn: $store.miniGlassMaterial).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                Row(L("使用彩色窗口控制按钮"), subtitle: L("关掉后只保留系统默认的灰度按钮")) {
                    Toggle("", isOn: $store.miniColoredControls).toggleStyle(.switch).labelsHidden()
                }
            }

            Text(L("Mini 窗口形态还在开发，这几项现在会记住，形态上线后直接生效。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 格式关联

private struct FormatSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var state = FormatBindingState()

    private var boundCount: Int { state.bindings.filter(\.isDefault).count }

    private var recommendedButtonTitle: String {
        state.remainingRecommended == 0
            ? L("常用格式已全部关联")
            : String(format: L("关联下一个格式（还剩 %d 项）"), state.remainingRecommended)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: boundCount > 0 ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(boundCount > 0 ? Color.green : Color.secondary)
                Text(String(format: L("已关联 %d / %d"), boundCount, state.bindings.count))
                    .font(.system(size: 12.5))
                Spacer()
                Button(recommendedButtonTitle) { state.associateNext() }
                    .controlSize(.small)
                    .disabled(state.remainingRecommended == 0 || !state.pending.isEmpty)
                Button(L("刷新")) { state.refresh() }
                    .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))

            Text(L("点一次只改一个格式。macOS 会弹一次确认框，选「使用千梭」；确认完再点下一个。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = state.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
            }

            ForEach(SettingsStore.formatGroups, id: \.self) { group in
                let items = state.bindings.filter { $0.group == group }
                if !items.isEmpty {
                    Card(group) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 14) }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(item.name).font(.system(size: 12.5))
                                        if item.cautious {
                                            Text(L("谨慎"))
                                                .font(.system(size: 9))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(item.extensions)
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if item.uti == nil {
                                    Text(L("系统未登记"))
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                } else {
                                    HStack(spacing: 6) {
                                        if state.pending.contains(item.id) {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Toggle("", isOn: Binding(
                                            get: { item.isDefault },
                                            set: { state.set(item, enabled: $0) }
                                        ))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .disabled(state.pending.contains(item.id))
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }

            Text(L("关闭开关会还原成接管之前那个默认程序；原本没有默认程序的格式会落到系统归档实用工具。JAR、DMG 这类格式交给千梭后，双击不再是启动或挂载，打开前会再问一次。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { state.refresh() }
    }
}

final class FormatBindingState: ObservableObject {
    @Published var bindings: [SettingsStore.FormatBinding] = []
    @Published var message: String?
    /// 正在等系统确认的格式。macOS 改默认程序可能弹一次授权框。
    @Published var pending: Set<String> = []

    func refresh() {
        bindings = SettingsStore.shared.currentFormatBindings()
    }

    /// 常用组里还没接管的、系统能登记的格式数量。
    var remainingRecommended: Int {
        let common = SettingsStore.formatGroups[0]
        return bindings.filter {
            $0.group == common && $0.uti != nil && !$0.isDefault
        }.count
    }

    func set(_ item: SettingsStore.FormatBinding, enabled: Bool) {
        message = nil
        guard !pending.contains(item.id) else { return }
        if enabled, item.cautious, !confirmCautious(item) { return }
        pending.insert(item.id)
        let id = item.id
        Task { @MainActor in
            // setFormatBinding 内部轮询实际状态，最多 6 秒，不会永久挂住。
            if let error = await SettingsStore.shared.setFormatBinding(item, enabled: enabled) {
                message = error
            }
            pending.remove(id)
            refresh()
        }
    }

    /// 「关联下一个」：一次只改一个格式，避免连着弹一串系统确认框。
    func associateNext() {
        message = nil
        let common = SettingsStore.formatGroups[0]
        guard let next = bindings.first(where: {
            $0.group == common && $0.uti != nil && !$0.isDefault
        }) else { return }
        set(next, enabled: true)
    }

    private func confirmCautious(_ item: SettingsStore.FormatBinding) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("把 %@ 交给千梭？"), item.name)
        alert.informativeText = L("接管后双击这类文件会变成打开压缩包内容；原本的启动、挂载或安装行为会变。随时可以回来关掉开关还原。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("仍然关联"))
        alert.window.level = .floating
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - 高级

private struct AdvancedSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @StateObject private var temp = TempFileState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(L("临时文件")) {
                Row(L("可清理的临时文件"), subtitle: temp.text) {
                    Button(L("清理")) {
                        _ = store.cleanTemporaryFiles()
                        temp.refresh()
                    }
                    .controlSize(.small)
                    .disabled(temp.size == 0)
                }
            }

            Card(L("维护")) {
                Row(L("恢复所有设置"), subtitle: L("外观、浏览、压缩、解压、格式关联都会回到默认值，已保存的密码一并清除")) {
                    Button(L("恢复默认值")) { confirmReset() }
                        .controlSize(.small)
                        .tint(.red)
                }
            }
        }
        .onAppear { temp.refresh() }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("恢复所有设置？")
        alert.informativeText = L("这会清掉千梭记住的全部偏好，包括解压位置与压缩格式。此操作不能撤销。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("恢复默认值"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.resetAll()
        temp.refresh()
    }
}

final class TempFileState: ObservableObject {
    @Published var size: Int64 = 0

    var text: String {
        size == 0 ? L("没有需要清理的文件") : ByteFormatter.string(size)
    }

    func refresh() {
        size = SettingsStore.shared.temporaryFileSize()
    }
}

// MARK: - 关于

private struct AboutSettingsPage: View {
    @ObservedObject var store: SettingsStore

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(L("千梭 Threxo"))
                    .font(.system(size: 17, weight: .semibold))
                Text(String(format: L("版本 %@（%@）"), version, build))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            Card(nil) {
                Row(L("检查更新"), subtitle: L("到发布页看看有没有新版本")) {
                    Button(L("打开下载页")) {
                        if let url = URL(string: "https://github.com/qujunxian/Threxo/releases/latest") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                Divider().padding(.leading, 14)
                Row(L("开源许可"), subtitle: L("内置 7-Zip 26.04，LGPL 许可要求随 App 可查阅")) {
                    Button(L("查看…")) { AboutWindowController.shared.show() }
                        .controlSize(.small)
                }
                Divider().padding(.leading, 14)
                Row(L("问题反馈"), subtitle: L("遇到问题或想提需求，到仓库开一个 issue")) {
                    Button(L("打开仓库")) {
                        if let url = URL(string: "https://github.com/qujunxian/Threxo/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Text(L("千梭全部功能免费，没有试用期与功能限制。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 通用组件

private struct Card<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(0.07))
                )
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#if DEBUG
/// 仅调试：把「处理器使用」卡片离屏渲染成 PNG，核对本机核心数文案与默认档。
/// 设置窗口很长、Aqua 的窗口位置又容易被系统挪到屏幕边缘，直接拍整窗不稳定。
@MainActor
func renderCoresPreview(to path: String) {
    struct CorePreview: View {
        @ObservedObject var store = SettingsStore.shared

        var body: some View {
            Card(L("处理器使用")) {
                Row(
                    L("最大可用核心数"),
                    subtitle: String(format: L("本机 %d 核，默认用满；调低可给别的程序留点余力"),
                                     SettingsStore.coreCount)
                ) {
                    Picker("", selection: $store.maxThreads) {
                        ForEach(SettingsStore.coreOptions, id: \.self) { count in
                            Text(String(format: L("%d 核"), count)).tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            .padding(24)
            .frame(width: 720, height: 160, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    snapshotView(CorePreview(), size: CGSize(width: 720, height: 160), to: path)
}
#endif
