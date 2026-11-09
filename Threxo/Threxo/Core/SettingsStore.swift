import Foundation
import AppKit
import Combine
import CoreServices
import ServiceManagement

/// 全局设置。所有可配置项集中在这里，读写 UserDefaults，改动立刻广播给界面。
///
/// 与 `CompressionOptions` 的分工：与「压缩产物长什么样」直接相关的留在
/// `CompressionOptions`（格式、级别、密码、删源），这里放工具行为（启动、外观、
/// 解压策略、列表呈现）。压缩页只是把 `CompressionOptions` 的控件搬过来。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

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
        archiveHandling = Self.read(defaults, Key.archiveHandling, .keep)
        filterSystemAux = defaults.object(forKey: Key.filterSystemAux) as? Bool ?? true
        filterDMGAux = defaults.object(forKey: Key.filterDMGAux) as? Bool ?? true
        quickExtractOnDoubleClick = defaults.object(forKey: Key.quickExtract) as? Bool ?? false
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
        archiveHandling = .keep
        filterSystemAux = true
        filterDMGAux = true
        quickExtractOnDoubleClick = false

        CompressionOptions.shared.resetToDefaults()
        applyAppearance()
    }

    // MARK: - 格式关联（只读查询）

    struct FormatBinding: Identifiable {
        let id: String
        let name: String
        let extensions: String
        let contentType: String

        var isDefault: Bool
    }

    /// Info.plist 里声明的归档类型，配上「当前系统里是不是千梭在默认打开」。
    func currentFormatBindings() -> [FormatBinding] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.qujunxian.Threxo"
        return Self.declaredFormats.map { item in
            let handler = LSCopyDefaultRoleHandlerForContentType(
                item.contentType as CFString,
                LSRolesMask.all
            )?.takeRetainedValue() as String?
            return FormatBinding(
                id: item.contentType,
                name: item.name,
                extensions: item.extensions,
                contentType: item.contentType,
                isDefault: handler == bundleID
            )
        }
    }

    private static let declaredFormats: [(name: String, extensions: String, contentType: String)] = [
        ("ZIP", ".zip .zipx .z01–.z99", "public.zip-archive"),
        ("7-Zip", ".7z", "org.7-zip.7-zip-archive"),
        ("RAR", ".rar .r00–.r99", "com.rarlab.rar-archive"),
        ("TAR", ".tar .tgz .tbz .tbz2 .txz", "public.tar-archive"),
        ("Gzip / TAR.GZ", ".gz .gzip", "org.gnu.gnu-zip-archive"),
        ("Bzip2 / TAR.BZ2", ".bz2 .bzip2", "public.bzip2-archive"),
        ("XZ / TAR.XZ", ".xz", "org.tukaani.xz-archive"),
        ("其他归档", "cab iso dmg wim jar", "public.archive")
    ]
}
