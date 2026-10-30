import Foundation

enum PathValidator {
    /// Returns a human-readable reason when an archive entry path is unsafe.
    static func unsafeReason(_ path: String) -> String? {
        if path.isEmpty { return "empty path" }
        if path.hasPrefix("/") { return "absolute POSIX path" }
        if path.hasPrefix("~") { return "home-relative path" }
        if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            return "absolute Windows path"
        }
        if path.hasPrefix("\\\\") { return "UNC path" }

        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if components.contains("..") { return "parent traversal" }
        return nil
    }

    /// True when `candidate` resolves inside `root`.
    static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
    }
}
