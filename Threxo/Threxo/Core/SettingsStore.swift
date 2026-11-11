import Foundation
import AppKit
import Combine
import CoreServices
import Darwin
import ServiceManagement
import FinderSync
import UniformTypeIdentifiers

/// 全局设置。所有可配置项集中在这里，读写 UserDefaults，改动立刻广播给界面。
///
/// 与 `CompressionOptions` 的分工：与「压缩产物长什么样」直接相关的留在
/// `CompressionOptions`（格式、级别、密码、删源），这里放工具行为（启动、外观、
/// 解压策略、列表呈现）。压缩页只是把 `CompressionOptions` 的控件搬过来。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// 本机实际物理核心数：Apple Silicon 会把性能核 + 能效核一起算进来，
    /// Intel 上则是物理核（不含超线程）。读不到 sysctl 时回落到逻辑处理器数。
    /// 设置页「处理器使用」的 1…n 与默认值都以此为准，不再写死 2/4/8。
    static let coreCount: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.processorCount)
    }()

    /// Picker 的全部可选项：1 … n。
    static var coreOptions: [Int] { Array(1...coreCount) }

    // MARK: - 枚举

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return L("自动")
            case .light: return L("浅色")
            case .dark: return L("深色")
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    enum LanguageMode: String, CaseIterable, Identifiable {
        case system
        case zhHans = "zh-Hans"
        case english = "en"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return L("跟随系统")
            case .zhHans: return L("简体中文")
            case .english: return L("English")
            }
        }

        /// 写入系统语言覆盖后要重启 App 才会重新加载 .strings。
        func apply() {
            let defaults = UserDefaults.standard
            switch self {
            case .system: defaults.removeObject(forKey: "AppleLanguages")
            case .zhHans: defaults.set(["zh-Hans"], forKey: "AppleLanguages")
            case .english: defaults.set(["en"], forKey: "AppleLanguages")
            }
            defaults.synchronize()
        }
    }

    enum BrowseMode: String, CaseIterable, Identifiable {
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

    enum ExtractionTarget: String, CaseIterable, Identifiable {
        case archiveFolder
        case lastUsed
        case ask

        var id: String { rawValue }

        var title: String {
            switch self {
            case .archiveFolder: return L("压缩包同级的新文件夹")
            case .lastUsed: return L("上次使用的位置")
            case .ask: return L("每次询问")
            }
        }
    }

    enum ConflictPolicy: String, CaseIterable, Identifiable {
        case rename
        case overwrite
        case ask

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rename: return L("自动改名，不覆盖")
            case .overwrite: return L("覆盖已有文件")
            case .ask: return L("每次询问")
            }
        }
    }

    enum ArchiveHandling: String, CaseIterable, Identifiable {
        case ask
        case trash
        case keep

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ask: return L("每次询问")
            case .trash: return L("移入废纸篓")
            case .keep: return L("保留文件")
            }
        }
    }

    // MARK: - 存储

    private enum Key {
        static let appearance = "threxo.settings.appearance"
        static let browseMode = "threxo.settings.browseMode"
        static let showAuxiliary = "threxo.settings.showAuxiliaryItems"
        static let extractionTarget = "threxo.settings.extractionTarget"
        static let lastExtractDir = "threxo.settings.lastExtractDirectory"
        static let conflictPolicy = "threxo.settings.conflictPolicy"
        static let revealAfterExtract = "threxo.settings.revealAfterExtract"
        static let closeAfterExtract = "threxo.settings.closeAfterExtract"
        static let archiveHandling = "threxo.settings.archiveHandling"
        static let filterSystemAux = "threxo.settings.filterSystemAux"
        static let filterDMGAux = "threxo.settings.filterDMGAux"
        static let quickExtract = "threxo.settings.quickExtractOnDoubleClick"
        static let language = "threxo.settings.language"
        static let showPasswordByDefault = "threxo.settings.showPasswordByDefault"
        static let maxThreads = "threxo.settings.maxThreads"
        static let finderExternalVolumes = "threxo.settings.finderExternalVolumes"
        static let miniDefaultOpen = "threxo.settings.miniDefaultOpen"
        static let miniGlass = "threxo.settings.miniGlass"
        static let miniColoredControls = "threxo.settings.miniColoredControls"
        static let vaultAutoSave = "threxo.settings.vaultAutoSave"
        static let vaultAutoTry = "threxo.settings.vaultAutoTry"
        static let vaultRequireAuth = "threxo.settings.vaultRequireAuth"
    }

    private let defaults: UserDefaults

    /// 防止开机自启的回滚赋值再次触发 `didSet` 形成递归。
    private var syncingLoginItem = false

    // MARK: - 通用

    /// 开机自启不落 UserDefaults：系统里的登录项状态才是唯一事实。
    @Published var launchAtLogin: Bool {
        didSet {
            guard !syncingLoginItem, oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }

    /// 登录项注册失败时给用户看的原因（开发签名或 App 不在 /Applications 时会失败）。
    @Published private(set) var loginItemError: String?

    @Published var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var browseMode: BrowseMode {
        didSet { defaults.set(browseMode.rawValue, forKey: Key.browseMode) }
    }

    @Published var showAuxiliaryItems: Bool {
        didSet { defaults.set(showAuxiliaryItems, forKey: Key.showAuxiliary) }
    }

    // MARK: - 解压

    @Published var extractionTarget: ExtractionTarget {
        didSet { defaults.set(extractionTarget.rawValue, forKey: Key.extractionTarget) }
    }

    @Published var conflictPolicy: ConflictPolicy {
        didSet { defaults.set(conflictPolicy.rawValue, forKey: Key.conflictPolicy) }
    }

    @Published var revealAfterExtract: Bool {
        didSet { defaults.set(revealAfterExtract, forKey: Key.revealAfterExtract) }
    }

    @Published var closeAfterExtract: Bool {
        didSet { defaults.set(closeAfterExtract, forKey: Key.closeAfterExtract) }
    }

    @Published var archiveHandling: ArchiveHandling {
        didSet { defaults.set(archiveHandling.rawValue, forKey: Key.archiveHandling) }
    }

    @Published var filterSystemAux: Bool {
        didSet { defaults.set(filterSystemAux, forKey: Key.filterSystemAux) }
    }

    @Published var filterDMGAux: Bool {
        didSet { defaults.set(filterDMGAux, forKey: Key.filterDMGAux) }
    }

    @Published var quickExtractOnDoubleClick: Bool {
        didSet { defaults.set(quickExtractOnDoubleClick, forKey: Key.quickExtract) }
    }

    // MARK: - 通用补充

    @Published var language: LanguageMode {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            language.apply()
        }
    }

    /// 密码框默认明文显示；关掉时用安全输入框。
    @Published var showPasswordByDefault: Bool {
        didSet { defaults.set(showPasswordByDefault, forKey: Key.showPasswordByDefault) }
    }

    /// 7zz 的 `-mmt` 上限，范围 1…`coreCount`，默认就是最大的那一档（用满本机核心）。
    /// 旧版本用 0 表示「不限制」，读取时统一迁移到 `coreCount`。
    @Published var maxThreads: Int {
        didSet { defaults.set(maxThreads, forKey: Key.maxThreads) }
    }

    /// 是否把 /Volumes 也交给访达扩展监视（外接盘右键菜单）。
    @Published var finderMenuOnExternalVolumes: Bool {
        didSet {
            defaults.set(finderMenuOnExternalVolumes, forKey: Key.finderExternalVolumes)
            Self.applyFinderDirectories(finderMenuOnExternalVolumes)
        }
    }

    /// 访达扩展监视的目录。关掉外接盘时只监视根卷。
    static func applyFinderDirectories(_ includeVolumes: Bool) {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        if includeVolumes { urls.insert(URL(fileURLWithPath: "/Volumes")) }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: - Mini

    @Published var miniDefaultOpen: Bool {
        didSet { defaults.set(miniDefaultOpen, forKey: Key.miniDefaultOpen) }
    }
    @Published var miniGlassMaterial: Bool {
        didSet { defaults.set(miniGlassMaterial, forKey: Key.miniGlass) }
    }
    @Published var miniColoredControls: Bool {
        didSet { defaults.set(miniColoredControls, forKey: Key.miniColoredControls) }
    }

    // MARK: - 密码本

    @Published var vaultAutoSave: Bool {
        didSet { defaults.set(vaultAutoSave, forKey: Key.vaultAutoSave) }
    }
    @Published var vaultAutoTry: Bool {
        didSet { defaults.set(vaultAutoTry, forKey: Key.vaultAutoTry) }
    }
    @Published var vaultRequireAuth: Bool {
        didSet { defaults.set(vaultRequireAuth, forKey: Key.vaultRequireAuth) }
    }

    /// 上一次手动选择过的解压目标目录，用于「上次使用的位置」。
    var lastExtractDirectory: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastExtractDir) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let newValue {
                defaults.set(newValue.path, forKey: Key.lastExtractDir)
            } else {
                defaults.removeObject(forKey: Key.lastExtractDir)
            }
        }
    }

    // MARK: - 初始化

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        launchAtLogin = SMAppService.mainApp.status == .enabled
        appearance = Self.read(defaults, Key.appearance, .system)
        browseMode = Self.read(defaults, Key.browseMode, .list)
        showAuxiliaryItems = defaults.object(forKey: Key.showAuxiliary) as? Bool ?? false

        extractionTarget = Self.read(defaults, Key.extractionTarget, .archiveFolder)
        conflictPolicy = Self.read(defaults, Key.conflictPolicy, .rename)
        revealAfterExtract = defaults.object(forKey: Key.revealAfterExtract) as? Bool ?? true
        closeAfterExtract = defaults.object(forKey: Key.closeAfterExtract) as? Bool ?? false
        archiveHandling = Self.read(defaults, Key.archiveHandling, .ask)
        filterSystemAux = defaults.object(forKey: Key.filterSystemAux) as? Bool ?? true
        filterDMGAux = defaults.object(forKey: Key.filterDMGAux) as? Bool ?? true
        quickExtractOnDoubleClick = defaults.object(forKey: Key.quickExtract) as? Bool ?? false

        language = Self.read(defaults, Key.language, .system)
        showPasswordByDefault = defaults.object(forKey: Key.showPasswordByDefault) as? Bool ?? false
        // 迁移旧值：没设过 / 旧版「全部可用」(0) → 本机最大核心数；
        // 手动选过但超过本机核心数（换机、虚拟机改配置）→ 收敛到最大档；
        // 仍落在 1…n 内的显式选择保留，不覆盖用户偏好。
        let savedThreads = defaults.object(forKey: Key.maxThreads) as? Int
        maxThreads = {
            guard let saved = savedThreads, saved > 0 else { return Self.coreCount }
            return min(saved, Self.coreCount)
        }()
        finderMenuOnExternalVolumes = defaults.object(forKey: Key.finderExternalVolumes) as? Bool ?? true
        miniDefaultOpen = defaults.object(forKey: Key.miniDefaultOpen) as? Bool ?? false
        miniGlassMaterial = defaults.object(forKey: Key.miniGlass) as? Bool ?? true
        miniColoredControls = defaults.object(forKey: Key.miniColoredControls) as? Bool ?? false
        vaultAutoSave = defaults.object(forKey: Key.vaultAutoSave) as? Bool ?? false
        vaultAutoTry = defaults.object(forKey: Key.vaultAutoTry) as? Bool ?? false
        vaultRequireAuth = defaults.object(forKey: Key.vaultRequireAuth) as? Bool ?? false
    }

    private static func read<T: RawRepresentable>(
        _ defaults: UserDefaults,
        _ key: String,
        _ fallback: T
    ) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else {
            return fallback
        }
        return value
    }

    // MARK: - 生效

    /// 外观立刻应用到所有窗口；system 交回系统决定。
    func applyAppearance() {
        NSApp?.appearance = appearance.appearance
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            // 注册失败就把开关拨回系统里的真实状态，避免界面显示已开启但实际没生效。
            let real = service.status == .enabled
            syncingLoginItem = true
            launchAtLogin = real
            syncingLoginItem = false
        }
    }

    // MARK: - 临时文件

    /// 导出中转目录（拖到访达时的临时产物）的总大小。
    func temporaryFileSize() -> Int64 {
        Self.sizeOfTemporaryItems()
    }

    /// 只清理本 App 创建的 `ThrexoExport-` / `ThrexoDrop-` 目录。
    func cleanTemporaryFiles() -> Int64 {
        let fm = FileManager.default
        var removed: Int64 = 0
        for url in Self.temporaryItems() {
            let size = Self.directorySize(url)
            if (try? fm.removeItem(at: url)) != nil { removed += size }
        }
        return removed
    }

    private static func temporaryItems() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return [] }
        return items.filter {
            $0.lastPathComponent.hasPrefix("ThrexoExport-")
                || $0.lastPathComponent.hasPrefix("ThrexoDrop-")
        }
    }

    private static func sizeOfTemporaryItems() -> Int64 {
        temporaryItems().reduce(0) { $0 + directorySize($1) }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - 访达扩展

    /// 重新启用扩展并让访达重新加载菜单项。
    /// 走 `pluginkit` 是因为没有公开 API 能触发 FinderSync 重新注册。
    func repairFinderExtension(extensionID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-e", "use", "-i", extensionID]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            loginItemError = error.localizedDescription
        }
    }

    // MARK: - 恢复默认

    /// 清掉本 App 写过的所有 key，然后重新读一遍。
    /// 密码本与访问过的目录一并清空，避免「恢复默认」之后还残留旧路径。
    func resetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("threxo.") {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        appearance = .system
        browseMode = .list
        showAuxiliaryItems = false
        extractionTarget = .archiveFolder
        conflictPolicy = .rename
        revealAfterExtract = true
        closeAfterExtract = false
        archiveHandling = .ask
        filterSystemAux = true
        filterDMGAux = true
        quickExtractOnDoubleClick = false
        language = .system
        showPasswordByDefault = false
        maxThreads = Self.coreCount
        finderMenuOnExternalVolumes = true
        miniDefaultOpen = false
        miniGlassMaterial = true
        miniColoredControls = false
        vaultAutoSave = false
        vaultAutoTry = false
        vaultRequireAuth = false

        CompressionOptions.shared.resetToDefaults()
        applyAppearance()
    }

    // MARK: - 格式关联

    struct FormatBinding: Identifiable, Equatable {
        let id: String
        let name: String
        let extensions: String
        let group: String
        let primaryExtension: String
        /// 双击会执行或被别的工具占用的格式，打开前先说明后果。
        let cautious: Bool
        /// 系统为该后缀登记的 UTI。nil 表示系统不认识，没法单独改默认程序。
        let uti: String?

        var isDefault: Bool
    }

    static let formatGroups = [
        L("常用压缩包"), L("单文件压缩"), L("磁盘映像与其他格式"), L("软件包（谨慎）"),
    ]

    /// 分组与后缀按原型 6-9 / 6-9-2 排。UTI 不写死，从后缀问系统，
    /// 免得不同 macOS 版本对同一个后缀的登记不一样。
    private static let declaredFormats: [(name: String, ext: String, extensions: String, group: Int, cautious: Bool)] = [
        ("ZIP", "zip", ".zip .zipx .z01–.z99", 0, false),
        ("7-Zip", "7z", ".7z", 0, false),
        ("RAR", "rar", ".rar .r00–.r99", 0, false),
        ("Comic RAR", "cbr", ".cbr", 0, false),
        ("TAR", "tar", ".tar .tgz .tbz .tbz2 .txz", 0, false),

        ("Gzip / TAR.GZ", "gz", ".gz .gzip", 1, false),
        ("Bzip2 / TAR.BZ2", "bz2", ".bz2 .bzip2", 1, false),
        ("XZ / TAR.XZ", "xz", ".xz", 1, false),
        ("LZMA", "lzma", ".lzma", 1, false),
        ("Lzip", "lz", ".lz", 1, false),

        ("DMG", "dmg", ".dmg", 2, true),
        ("ISO", "iso", ".iso", 2, true),
        ("CAB", "cab", ".cab", 2, false),
        ("CPIO", "cpio", ".cpio", 2, false),
        ("LHA / LZH", "lzh", ".lha .lzh", 2, false),
        ("ARJ", "arj", ".arj", 2, false),
        ("XAR", "xar", ".xar", 2, false),
        ("RPM", "rpm", ".rpm", 2, false),
        ("MSI", "msi", ".msi", 2, true),
        ("WIM", "wim", ".wim", 2, false),
        ("Z", "z", ".z", 2, false),

        ("JAR", "jar", ".jar", 3, true),
        ("APK", "apk", ".apk", 3, true),
        ("SPK", "spk", ".spk", 3, true),
    ]

    func currentFormatBindings() -> [FormatBinding] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.qujunxian.Threxo"
        return Self.declaredFormats.map { item in
            // dyn.* 是系统按后缀临时生成的 UTI，LaunchServices 不给它登记 handler，
            // 设了也不会生效。这类格式在界面上标成「系统未登记」并禁用开关。
            let resolved = UTType(filenameExtension: item.ext)?.identifier
            let uti = resolved?.hasPrefix("dyn.") == true ? nil : resolved
            let handler = uti.flatMap {
                LSCopyDefaultRoleHandlerForContentType($0 as CFString, LSRolesMask.all)?
                    .takeRetainedValue() as String?
            }
            return FormatBinding(
                id: item.ext,
                name: item.name,
                extensions: item.extensions,
                group: Self.formatGroups[item.group],
                primaryExtension: item.ext,
                cautious: item.cautious,
                uti: uti,
                isDefault: handler == bundleID
            )
        }
    }

    /// 切换某个格式的默认程序。
    ///
    /// 两个本机实测结论：
    ///   1. `LSSetDefaultRoleHandlerForContentType` 返回 noErr 但不生效，必须用 NSWorkspace。
    ///   2. `setDefaultApplication` 的 completion 有时永远不回来，但**更改已经生效**。
    ///      所以这里不 await 它，改为发起后轮询实际状态，避免界面永远转圈。
    /// - Returns: nil 表示成功，否则是一句可展示的错误。
    func setFormatBinding(_ item: FormatBinding, enabled: Bool) async -> String? {
        guard item.uti != nil,
              let type = UTType(filenameExtension: item.primaryExtension) else {
            return L("系统没登记这个后缀，改不了默认打开方式。")
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.qujunxian.Threxo"
        let key = "threxo.format.previous." + type.identifier

        let target: URL
        if enabled {
            // 记下原来的默认程序（没有默认就存空串），关掉开关时才能还原。
            let current = LSCopyDefaultRoleHandlerForContentType(
                type.identifier as CFString, LSRolesMask.all
            )?.takeRetainedValue() as String?
            if current != bundleID {
                defaults.set(current ?? "", forKey: key)
            }
            target = Bundle.main.bundleURL
        } else {
            let saved = defaults.string(forKey: key)
            // 原本没有默认程序的格式（例如我们自定义 UTI 的那些），
            // 关掉开关时落到系统归档实用工具，不能把空串当 bundle ID 去查。
            let previous = (saved?.isEmpty == false) ? saved! : "com.apple.archiveutility"
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: previous
            ) else {
                return String(format: L("找不到原来的默认程序（%@）"), previous)
            }
            target = url
        }

        Task.detached {
            try? await NSWorkspace.shared.setDefaultApplication(at: target, toOpen: type)
        }

        // 系统有时要等确认框、有时只是写盘慢，实测 6 秒会误判成失败。
        // 以实际状态为准，最多等 15 秒；最后一刻再读一次，避免显示错误却已经生效。
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let handler = LSCopyDefaultRoleHandlerForContentType(
                type.identifier as CFString, LSRolesMask.all
            )?.takeRetainedValue() as String?
            let settled = enabled ? (handler == bundleID) : (handler != bundleID)
            if settled {
                if !enabled { defaults.removeObject(forKey: key) }
                return nil
            }
        }
        let finalHandler = LSCopyDefaultRoleHandlerForContentType(
            type.identifier as CFString, LSRolesMask.all
        )?.takeRetainedValue() as String?
        let finallySettled = enabled ? (finalHandler == bundleID) : (finalHandler != bundleID)
        if finallySettled, !enabled { defaults.removeObject(forKey: key) }
        return finallySettled
            ? nil
            : L("系统处理这次更改比较慢，已刷新状态；如果开关没变，请再点一次。")
    }

}
