import SwiftUI
import AppKit
import Combine

/// 压缩设置面板（压缩方式 / 密码 / 排除 Mac 资源 / 压缩完成后删源，四段式）：
/// 压缩方式滑杆 / 密码 / 排除 Mac 资源 / 压缩完成后删除源文件。
struct CompressOptionsView: View {
    @ObservedObject var options: CompressionOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card

            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("排除 Mac 资源文件"), isOn: $options.excludeMacResources)
                Toggle(L("压缩完成后把源文件移到废纸篓"), isOn: $options.deleteSourceAfterCompress)
                Text(L("源文件会进废纸篓，可从废纸篓恢复。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(String(format: L("解压支持：%@"), CompressionOptions.extractableHint))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("压缩方式："))
                    .font(.callout)
                Text(options.level.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(options.format.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Slider(value: levelBinding, in: 0...3, step: 1)
                .disabled(!options.format.supportsLevel)

            HStack(spacing: 0) {
                ForEach(CompressionLevel.allCases) { level in
                    Text(level.title)
                        .font(.caption2)
                        .foregroundStyle(level == options.level ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: alignment(for: level))
                }
            }

            if !options.format.supportsLevel {
                Text(L("TAR 只打包不压缩，没有压缩级别。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            passwordSection
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("密码："))
                    .font(.callout)
                    .frame(width: 44, alignment: .leading)
                SecureField("", text: $options.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!options.format.supportsPassword)
            }
            HStack(spacing: 8) {
                Text(L("重复："))
                    .font(.callout)
                    .frame(width: 44, alignment: .leading)
                SecureField("", text: $options.passwordRepeat)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!options.format.supportsPassword || options.password.isEmpty)
            }

            if let mismatch = options.passwordValidationMessage {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if let reason = options.passwordUnavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if options.format.offersAESChoice {
                Toggle(L("使用 AES-256 加密"), isOn: $options.zipAES256)
                    .disabled(options.password.isEmpty)
                    .font(.callout)
            } else if options.format == .sevenZip {
                Label(L("7Z 固定使用 AES-256 加密"), systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if options.format.supportsPassword {
                Text(L("密码只保留在本次运行中，不会写入磁盘。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private var levelBinding: Binding<Double> {
        Binding(
            get: { Double(options.level.rawValue) },
            set: { options.level = CompressionLevel(rawValue: Int($0.rounded())) ?? .normal }
        )
    }

    private func alignment(for level: CompressionLevel) -> Alignment {
        switch level {
        case .store: return .leading
        case .slow: return .trailing
        default: return .center
        }
    }
}

/// 解压加密归档时的密码输入框。
struct PasswordSheet: View {
    let prompt: AppModel.PasswordPrompt
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @StateObject private var state = PasswordFieldState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                Text(prompt.title)
                    .font(.headline)
            }

            Text(prompt.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(L("密码"), text: $state.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            HStack {
                Spacer()
                Button(L("取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("解压")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.text.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func submit() {
        guard !state.text.isEmpty else { return }
        onSubmit(state.text)
    }
}

final class PasswordFieldState: ObservableObject {
    @Published var text = ""
}
