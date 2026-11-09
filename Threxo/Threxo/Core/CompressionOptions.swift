import Foundation
import AppKit
import Combine

/// 可**创建**的归档格式。
///
/// 这份清单是照内置 7-Zip 26.04 的实测结果收敛的，能真建出来才列：
/// ZSTD / LZ4 / Brotli / LZIP / LRZIP / AAR / SNAPPY 由 7-Zip ZS 分支提供，
/// 官方 `7zz` 对这几种返回 rc=2；DMG / ISO 只能解压不能创建。
/// 官方 7zz 能建的就只有下面 7 种，所以只暴露这 7 种。
enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip
    case sevenZip = "7z"
    case tar
    case gzip
    case bzip2
    case xz
    case wim

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z"
        case .tar: return "TAR"
        case .gzip: return "GZIP"
        case .bzip2: return "BZIP2"
        case .xz: return "XZ"
        case .wim: return "WIM"
        }
    }

    /// 传给 `7zz` 的 `-t` 参数。
    var typeFlag: String { "-t\(rawValue)" }

    /// 生成文件的后缀。gzip/bzip2/xz 装目录时是「先 tar 再压」，所以是两层后缀。
    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .gzip: return "tar.gz"
        case .bzip2: return "tar.bz2"
        case .xz: return "tar.xz"
        case .wim: return "wim"
        }
    }

    var symbolName: String {
        switch self {
        case .zip: return "doc.zipper"
        case .sevenZip: return "archivebox.fill"
        case .tar: return "shippingbox"
        case .gzip: return "arrow.down.circle"
        case .bzip2: return "arrow.down.circle"
        case .xz: return "arrow.down.circle"
        case .wim: return "externaldrive"
        }
    }

    /// tar 只打包不压缩，`-mx` 没有意义，界面上把级别控件置灰。
    var supportsLevel: Bool { self != .tar }

    /// 实测：tar 与 wim 收到 `-p` 会被**静默忽略**（rc=0 但内容没加密），
    /// gzip/bzip2/xz 根本没有加密能力。只有 zip 与 7z 能给出真正的 AES-256。
    var supportsPassword: Bool { self == .zip || self == .sevenZip }

    /// zip 默认是弱加密（ZipCrypto），必须显式 `-mem=AES256` 才是 AES-256；
    /// 7z 恒为 7zAES(AES-256)，没有可选项。
    var offersAESChoice: Bool { self == .zip }

    /// 单流压缩器：一次只能压一个文件，遇到目录或多项时必须先打成 tar。
    var isSingleStream: Bool { self == .gzip || self == .bzip2 || self == .xz }

    /// 能否分卷。7zz 的 `-v` 只对 zip 与 7z 实测可靠；
    /// 单流压缩器（gz/bz2/xz）本身就是一个连续的字节流，切段后没有索引可依，直接不提供。
    var supportsVolume: Bool { self == .zip || self == .sevenZip }

    /// 能否在容器里标「文件名是 UTF-8」。只有 zip 有这个位。
    var supportsUTF8Names: Bool { self == .zip }
}

/// 压缩级别。档位语义对齐 7-Zip 的 `-mx`，界面用五档滑杆呈现。
///
/// 五档而不是九档：`-mx` 的 2/4/6/8 在实际产物上几乎看不出差别，
/// 滑杆给出五段正好对应「更快 → 更小」的直觉，也不会让人停顿在中间档位上挑。
enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0
    case fast = 1
    case normal = 2
    case strong = 3
    case extreme = 4

    var id: Int { rawValue }

    /// 7-Zip 的 `-mx`：0=仅存储，1=最快，5=标准，7=更强，9=极限。
    var mx: Int {
        switch self {
        case .store: return 0
        case .fast: return 1
        case .normal: return 5
        case .strong: return 7
        case .extreme: return 9
        }
    }

    var title: String {
        switch self {
        case .store: return L("存储")
        case .fast: return L("快速")
        case .normal: return L("标准")
        case .strong: return L("更强")
        case .extreme: return L("极限")
        }
    }

    /// 滑杆下方的短说明，越靠右越慢越小。
    var hint: String {
        switch self {
        case .store: return L("不压缩，只打包")
        case .fast: return L("最快，适合临时传")
        case .normal: return L("日常均衡")
        case .strong: return L("更小，速度可接受")
        case .extreme: return L("最小，大文件很慢")
        }
    }
}

/// 创建压缩包时的用途预设。
///
/// 每张卡不是黑盒：它只是把「格式 + 强度 + 两个开关」这一组参数一次性拨到位，
/// 拨完之后所有控件仍然可改，改过的组合在概览里显示为「自定义」。
enum CompressionPurpose: String, CaseIterable, Identifiable {
    case general
    case windows
    case mac
    case linux
    case smallest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("通用分享")
        case .windows: return L("Windows 用户")
        case .mac: return L("Mac 之间传递")
        case .linux: return L("Linux 与服务器")
        case .smallest: return L("尽可能小")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return L("谁都能解，最稳")
        case .windows: return L("中文名不乱码")
        case .mac: return L("保住资源分支")
        case .linux: return L("保留权限位")
        case .smallest: return L("体积优先")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "paperplane"
        case .windows: return "pc"
        case .mac: return "laptopcomputer"
        case .linux: return "server.rack"
        case .smallest: return "arrow.down.right.and.arrow.up.left"
        }
    }

    var format: ArchiveFormat {
        switch self {
        case .general, .windows, .mac: return .zip
        case .linux: return .gzip
        case .smallest: return .sevenZip
        }
    }

    var level: CompressionLevel {
        switch self {
        case .general, .windows, .mac, .linux: return .normal
        case .smallest: return .extreme
        }
    }

    /// 要不要把 `__MACOSX`、`.DS_Store`、`._*` 打进包里。
    var excludesMacResources: Bool { self != .mac }

    /// zip 里强制写 UTF-8 文件名。Windows 自带解压器按当前代码页读名字，
    /// 不带这个标记的中文名在 GBK 环境下会变成问号。
    var forcesUTF8Names: Bool { self == .windows || self == .general || self == .mac }

    /// 顺手把 Windows 在自己目录里留的 `Thumbs.db`、`desktop.ini` 也剔掉。
    /// 「通用分享」不打这个开关——对方可能真的需要这些文件；
    /// 明确选「Windows 用户」时它们的价值是负的，才替用户剔掉。
    var excludesWindowsJunk: Bool { self == .windows }
}

/// 分卷大小。产物是 `xxx.zip.001`、`.002`……，只有 zip 与 7z 支持。
enum VolumeSize: String, CaseIterable, Identifiable {
    case none
    case mb100
    case mb1000
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L("不分割")
        case .mb100: return L("每卷 100 MB")
        case .mb1000: return L("每卷 1 GB")
        case .custom: return L("自定义")
        }
    }

    /// 传给 `7zz -v` 的兆字节数；`nil` 表示不分卷。
    func megabytes(custom: Int) -> Int? {
        switch self {
        case .none: return nil
        case .mb100: return 100
        case .mb1000: return 1000
        case .custom: return max(1, custom)
        }
    }
}

/// 压缩设置：跨会话记住格式/级别/两个勾选项，但**密码永不落盘**。
///
/// 密码只存在内存里，App 退出即丢失。理由是密码写进 UserDefaults 等于明文入库，
/// 而「下次自动带出上次的密码」带来的便利远小于泄露代价。
final class CompressionOptions: ObservableObject {
    static let shared = CompressionOptions()

    private enum Key {
        static let format = "threxo.compress.format"
        static let level = "threxo.compress.level"
        static let excludeMac = "threxo.compress.excludeMacResources"
        static let deleteSource = "threxo.compress.deleteSourceAfterCompress"
        static let zipAES = "threxo.compress.zipAES256"
        static let verify = "threxo.compress.verifyAfterCompress"
        static let utf8Names = "threxo.compress.forceUTF8Names"
        static let windowsJunk = "threxo.compress.excludesWindowsJunk"
        static let volumeSize = "threxo.compress.volumeSize"
        static let customVolumeMB = "threxo.compress.customVolumeMB"
    }

    private let defaults: UserDefaults

    @Published var format: ArchiveFormat {
        didSet { defaults.set(format.rawValue, forKey: Key.format) }
    }

    @Published var level: CompressionLevel {
        didSet { defaults.set(level.rawValue, forKey: Key.level) }
    }

    /// 排除 `__MACOSX`、`.DS_Store`、`._*`（AppleDouble）。
    /// 这是纯文本/源码/文档分享时最常见的「垃圾文件」，默认打开。
    @Published var excludeMacResources: Bool {
        didSet { defaults.set(excludeMacResources, forKey: Key.excludeMac) }
    }

    /// 压缩成功后才把源文件移到废纸篓。默认关闭——删数据这种事不能默认开。
    @Published var deleteSourceAfterCompress: Bool {
        didSet { defaults.set(deleteSourceAfterCompress, forKey: Key.deleteSource) }
    }

    /// zip 是否使用 AES-256（默认是）。关掉则退回 ZipCrypto，仅为兼容极老的解压工具。
    @Published var zipAES256: Bool {
        didSet { defaults.set(zipAES256, forKey: Key.zipAES) }
    }

    /// 压缩完成后追加一次 `7zz t` 完整性校验。
    ///
    /// 默认关闭：校验要完整读一遍归档并逐项算 CRC，等于把 IO 成本翻一倍。
    /// 但它是唯一能拦住「写盘中途失败 / 磁盘满 / 文件被截断」这类静默损坏的手段，
    /// 且开启后一旦校验失败就不会执行删源文件，所以给需要交付或归档的场景留了开关。
    @Published var verifyAfterCompress: Bool {
        didSet { defaults.set(verifyAfterCompress, forKey: Key.verify) }
    }

    /// zip 里给文件名打上 UTF-8 标记。默认开——中文名交给 Windows 自带解压器时才不乱码。
    @Published var forceUTF8Names: Bool {
        didSet { defaults.set(forceUTF8Names, forKey: Key.utf8Names) }
    }

    /// 压缩时剔除 `Thumbs.db`、`desktop.ini`。默认关，由「Windows 用户」用途卡打开。
    @Published var excludesWindowsJunk: Bool {
        didSet { defaults.set(excludesWindowsJunk, forKey: Key.windowsJunk) }
    }

    @Published var volumeSize: VolumeSize {
        didSet { defaults.set(volumeSize.rawValue, forKey: Key.volumeSize) }
    }

    @Published var customVolumeMB: Int {
        didSet { defaults.set(customVolumeMB, forKey: Key.customVolumeMB) }
    }

    /// 不落盘。
    @Published var password: String = ""
    @Published var passwordRepeat: String = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 首次启动的默认值：ZIP + 正常 + 排除 Mac 资源 + 不删源文件 + AES-256。
        if let raw = defaults.string(forKey: Key.format), let value = ArchiveFormat(rawValue: raw) {
            format = value
        } else {
            format = .zip
        }
        if defaults.object(forKey: Key.level) != nil {
            level = CompressionLevel(rawValue: defaults.integer(forKey: Key.level)) ?? .normal
        } else {
            level = .normal
        }
        excludeMacResources = defaults.object(forKey: Key.excludeMac) as? Bool ?? true
        deleteSourceAfterCompress = defaults.object(forKey: Key.deleteSource) as? Bool ?? false
        zipAES256 = defaults.object(forKey: Key.zipAES) as? Bool ?? true
        verifyAfterCompress = defaults.object(forKey: Key.verify) as? Bool ?? false
        forceUTF8Names = defaults.object(forKey: Key.utf8Names) as? Bool ?? true
        excludesWindowsJunk = defaults.object(forKey: Key.windowsJunk) as? Bool ?? false
        if let raw = defaults.string(forKey: Key.volumeSize), let value = VolumeSize(rawValue: raw) {
            volumeSize = value
        } else {
            volumeSize = .none
        }
        let storedMB = defaults.integer(forKey: Key.customVolumeMB)
        customVolumeMB = storedMB > 0 ? storedMB : 500
    }

    // MARK: - Derived

    /// 当前格式是否真的会用上密码。格式不支持时界面置灰，逻辑上也不能带密码。
    var passwordInUse: Bool {
        format.supportsPassword && !password.isEmpty
    }

    /// 两次输入不一致时给出的提示；nil 表示可以开始压缩。
    var passwordValidationMessage: String? {
        guard format.supportsPassword, !password.isEmpty else { return nil }
        if password != passwordRepeat { return L("两次输入的密码不一致") }
        return nil
    }

    var canCompress: Bool { passwordValidationMessage == nil }

    /// 压缩时追加在目标与源之间的参数。
    /// - Parameter includeVolume: 是否带上分卷参数。访达右键的静默压缩传 false。
    func extraArguments(includeVolume: Bool = true) -> [String] {
        buildArguments(includePassword: true, includeVolume: includeVolume)
    }

    /// 给界面看的参数摘要（隐藏密码），用来核对「概览里写的」和「实际下发的」是不是一套。
    func argumentSummary() -> [String] {
        buildArguments(includePassword: false, includeVolume: true)
    }

    private func buildArguments(includePassword: Bool, includeVolume: Bool) -> [String] {
        var args = [format.typeFlag]
        if format.supportsLevel {
            args.append("-mx=\(level.mx)")
        }
        args.append(contentsOf: excludeArguments())
        if format.supportsUTF8Names, forceUTF8Names {
            // `-mcu=on`：把文件名标成 UTF-8。macOS 本来就写 UTF-8，
            // 但 zip 头里那个「这是 UTF-8」的标记默认不带，Windows 只能按代码页猜。
            args.append("-mcu=on")
        }
        if format.supportsPassword, !password.isEmpty {
            if includePassword {
                args.append("-p\(password)")
            }
            if format == .zip, zipAES256 {
                // 不加这句 zip 只有 ZipCrypto，AES-256 必须显式声明。
                args.append("-mem=AES256")
            }
        }
        if includeVolume, format.supportsVolume,
           let megabytes = volumeSize.megabytes(custom: customVolumeMB) {
            args.append("-v\(megabytes)m")
        }
        return args
    }

    /// 当前参数组合命中的用途卡；`nil` 表示用户改过，显示「自定义」。
    var matchingPurpose: CompressionPurpose? {
        CompressionPurpose.allCases.first { purpose in
            purpose.format == format
                && purpose.level == level
                && purpose.excludesMacResources == excludeMacResources
                && purpose.excludesWindowsJunk == excludesWindowsJunk
                && purpose.forcesUTF8Names == (forceUTF8Names && format.supportsUTF8Names)
        }
    }

    /// 点用途卡：一次性把格式、强度、辅助文件、UTF-8 标记拨到位，之后仍可逐项改。
    func apply(_ purpose: CompressionPurpose) {
        format = purpose.format
        level = purpose.level
        excludeMacResources = purpose.excludesMacResources
        excludesWindowsJunk = purpose.excludesWindowsJunk
        if purpose.format.supportsUTF8Names {
            forceUTF8Names = purpose.forcesUTF8Names
        }
        // 用途卡改的是「产物长什么样」，不该顺手动用户的密码。
    }

    /// 排除 Mac 资源派生文件的通配规则。
    /// `-xr!` 是「按通配符递归排除」，能覆盖任意层级的同名文件与目录。
    static let macResourceExcludes = ["-xr!__MACOSX", "-xr!.DS_Store", "-xr!._*"]

    /// Windows 在自己管理的目录里留下的索引与配置，对拿到包的人基本只有噪音。
    static let windowsJunkExcludes = ["-xr!Thumbs.db", "-xr!desktop.ini"]

    /// 当前设置下要排除的辅助文件。压缩与「先打 tar 再压」的中转步骤共用这一份，
    /// 免得两条路径排出不一样的内容。
    func excludeArguments() -> [String] {
        var args: [String] = []
        if excludeMacResources { args.append(contentsOf: Self.macResourceExcludes) }
        if excludesWindowsJunk { args.append(contentsOf: Self.windowsJunkExcludes) }
        return args
    }

    /// 界面上的能力说明。7zz `i` 实测可读的常见格式，避免夸大。
    static let extractableHint = "7z · zip · rar · tar · gz · bz2 · xz · cab · iso · dmg · wim"

    /// 密码字段是否可用（格式不支持时给出置灰原因）。
    var passwordUnavailableReason: String? {
        format.supportsPassword ? nil : String(format: L("%@ 格式不支持加密"), format.displayName)
    }

    func resetPassword() {
        password = ""
        passwordRepeat = ""
    }

    /// 「恢复所有设置」用：压缩项回到首次启动的默认值。
    func resetToDefaults() {
        format = .zip
        level = .normal
        excludeMacResources = true
        excludesWindowsJunk = false
        deleteSourceAfterCompress = false
        zipAES256 = true
        verifyAfterCompress = false
        forceUTF8Names = true
        volumeSize = .none
        customVolumeMB = 500
        resetPassword()
    }
}
