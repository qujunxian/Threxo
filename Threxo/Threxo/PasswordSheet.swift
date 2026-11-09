import SwiftUI
import AppKit
import Combine

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
