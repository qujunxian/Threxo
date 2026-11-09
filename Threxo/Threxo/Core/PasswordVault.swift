import Foundation
import Security
import Combine

/// 密码本：把「哪个归档用哪个密码」记进系统钥匙串。
///
/// 不落 UserDefaults，也不写文件。每条记录用归档文件名做 account，
/// 密码放在 kSecValueData，备注放 kSecAttrComment。同名覆盖更新。
struct VaultEntry: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var password: String
    var note: String
}

final class PasswordVault: ObservableObject {
    static let shared = PasswordVault()

    private static let service = "com.qujunxian.Threxo.passwords"
    @Published private(set) var entries: [VaultEntry] = []
    @Published private(set) var lastError: String?

    private init() { reload() }

    /// 是否解锁过（设置页里「查看需要认证」时用）。
    @Published var unlocked = true

    func reload() {
        // macOS 上「kSecMatchLimitAll + kSecReturnData」会直接报 errSecParam(-50)，
        // 所以分两步：先只拿属性列出 account，再逐条把密码读出来。
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &item)
        guard status == errSecSuccess else {
            // 一条都没有是正常状态，不是错误。
            if status != errSecItemNotFound {
                lastError = String(format: L("读取钥匙串失败（%d）"), status)
            } else {
                lastError = nil
            }
            entries = []
            return
        }
        let rows: [[String: Any]] = (item as? [[String: Any]]) ?? (item as? [String: Any]).map { [$0] } ?? []
        var result: [VaultEntry] = []
        for row in rows {
            guard let name = row[kSecAttrAccount as String] as? String else { continue }
            let note = row[kSecAttrComment as String] as? String ?? ""
            result.append(VaultEntry(name: name, password: passwordData(for: name), note: note))
        }
        entries = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastError = nil
    }

    private func passwordData(for name: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 按归档名查密码。先精确匹配文件名，再按「以这个名字结尾」匹配一次，
    /// 这样从邮件里下载下来的 `报告 (1).zip` 也能命中之前记的 `报告.zip`。
    func password(for archiveName: String) -> String? {
        guard !archiveName.isEmpty else { return nil }
        if let exact = entries.first(where: { $0.name == archiveName }) { return exact.password }
        let lowered = archiveName.lowercased()
        let stem = (archiveName as NSString).deletingPathExtension.lowercased()
        let candidates = entries.filter { entry in
            let name = entry.name.lowercased()
            return name.hasSuffix(lowered) || lowered.hasSuffix(name) || name.hasPrefix(stem)
        }
        return candidates.first?.password
    }

    @discardableResult
    func upsert(name: String, password: String, note: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !password.isEmpty else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        let mutable: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrComment as String: note,
            kSecAttrLabel as String: key,
        ]
        let addAttrs = mutable.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]) { _, new in new }
        let status = SecItemAdd(base.merging(addAttrs) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(base as CFDictionary, mutable as CFDictionary)
            lastError = update == errSecSuccess ? nil : String(format: L("更新钥匙串失败（%d）"), update)
            if update == errSecSuccess { reload() }
            return update == errSecSuccess
        }
        lastError = status == errSecSuccess ? nil : String(format: L("写入钥匙串失败（%d）"), status)
        if status == errSecSuccess { reload() }
        return status == errSecSuccess
    }

    func remove(name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            lastError = String(format: L("删除钥匙串记录失败（%d）"), status)
        }
        reload()
    }

    /// 「恢复所有设置」不清密码本，这里只清钥匙串里的错误提示。
    func clearError() { lastError = nil }
}
