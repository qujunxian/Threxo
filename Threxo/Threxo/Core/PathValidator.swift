import Foundation

/// 归档条目路径的安全校验。
///
/// 分成两类处理：`isFatal` 的（绝对路径、盘符、UNC、`~`）一定会让 7-Zip
/// 把内容搬到奇怪的地方（实测 `/etc/x` 会落成 `<目标>/etc/x`），必须拦下来问一句；
/// 其余的（`..`）7-Zip 会剥掉层级落平在目标目录里，安全但会静默改名，只做告知。
enum PathValidator {
    enum Problem: String, Sendable, Equatable, CaseIterable {
        case emptyPath
        case absolutePOSIX
        case homeRelative
        case absoluteWindows
        case unc
        case parentTraversal

        /// 是否需要中断解压征求用户意见。
        var isFatal: Bool {
            switch self {
            case .absolutePOSIX, .homeRelative, .absoluteWindows, .unc:
                return true
            case .emptyPath, .parentTraversal:
                return false
            }
        }

        var text: String {
            switch self {
            case .emptyPath: return L("条目名为空")
            case .absolutePOSIX: return L("绝对路径")
            case .homeRelative: return L("家目录相对路径")
            case .absoluteWindows: return L("Windows 盘符路径")
            case .unc: return L("网络共享路径")
            case .parentTraversal: return L("向上跳级（../）")
            }
        }
    }

    /// 路径不安全时返回原因，安全则返回 nil。
    static func problem(in path: String) -> Problem? {
        if path.isEmpty { return .emptyPath }
        if path.hasPrefix("/") { return .absolutePOSIX }
        if path.hasPrefix("~") { return .homeRelative }
        if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            return .absoluteWindows
        }
        if path.hasPrefix("\\\\") { return .unc }

        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if components.contains("..") { return .parentTraversal }
        return nil
    }

    /// `candidate` 解析符号链接后是否仍在 `root` 之内。
    static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
    }
}
