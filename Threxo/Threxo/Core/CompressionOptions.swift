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
}

/// 压缩级别。档位语义对齐 7-Zip 的 `-mx`，界面用四档滑杆呈现。
enum CompressionLevel: Int, CaseIterable, Identifiable {
    case store = 0
    case fast = 1
    case normal = 2
    case slow = 3

    var id: Int { rawValue }

    /// 7-Zip 的 `-mx`：0=仅存储，1=最快，5=标准，9=极限。
    var mx: Int {
        switch self {
        case .store: return 0
        case .fast: return 1
        case .normal: return 5
        case .slow: return 9
        }
    }

    var title: String {
        switch self {
        case .store: return L("存储")
        case .fast: return L("快速")
        case .normal: return L("正常")
        case .slow: return L("慢速")
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
    func extraArguments() -> [String] {
        var args = [format.typeFlag]
        if format.supportsLevel {
            args.append("-mx=\(level.mx)")
        }
        if excludeMacResources {
            args.append(contentsOf: Self.macResourceExcludes)
        }
        if format.supportsPassword, !password.isEmpty {
            args.append("-p\(password)")
            if format == .zip, zipAES256 {
                // 不加这句 zip 只有 ZipCrypto，AES-256 必须显式声明。
                args.append("-mem=AES256")
            }
        }
        return args
    }

    /// 排除 Mac 资源派生文件的通配规则。
    /// `-xr!` 是「按通配符递归排除」，能覆盖任意层级的同名文件与目录。
    static let macResourceExcludes = ["-xr!__MACOSX", "-xr!.DS_Store", "-xr!._*"]

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
}
