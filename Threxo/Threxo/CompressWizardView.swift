import SwiftUI
import AppKit
import Combine

/// 压缩向导的展开状态。用 ObservableObject 而不是 @State，
/// 与 ContentView 里 DropState / HeaderState 的理由相同（见那里的注释）。
final class CompressWizardState: ObservableObject {
    @Published var isPresented: Bool
    /// 点「选择内容并压缩…」后先把面板收掉，`onDismiss` 里再走选文件流程。
    @Published var pendingCompress = false

    init() {
        #if DEBUG
        // 仅调试构建：`THREXO_SHOW_WIZARD=1` 直接展开向导，方便脚本截图核对布局。
        isPresented = ProcessInfo.processInfo.environment["THREXO_SHOW_WIZARD"] == "1"
        #else
        isPresented = false
        #endif
    }
}

/// 创建压缩包向导：先问「拿来干什么」，再把结果摊开给人看。
///
/// 用途卡不是黑盒——点一下只是把格式、强度、两个开关拨到位，
/// 下面概览里立刻显示最终会下发的 7zz 参数，用户随时能改回自定义。
struct CompressWizardView: View {
    @ObservedObject var options: CompressionOptions
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @StateObject private var ui = WizardState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                sections
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 700)
        .frame(maxHeight: 760)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            purposeSection
            levelSection
            summarySection
            advancedSection
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("创建压缩包"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L("先选用途，参数自动配好，还能逐项改"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - 用途

    private var purposeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("这个包拿来干什么"), note: L("不选也行，参数会按当前设置走"))
            HStack(spacing: 10) {
                ForEach(CompressionPurpose.allCases) { purpose in
                    PurposeCard(
                        purpose: purpose,
                        selected: options.matchingPurpose == purpose
                    ) {
                        options.apply(purpose)
                    }
                }
            }
        }
    }

    // MARK: - 强度

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle(L("压缩强度"), note: nil)
                Spacer()
                Text(options.level.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(options.format.supportsLevel ? Color.accentColor : Color.secondary)
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
                Text(L("更快"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(options.format.supportsLevel ? options.level.hint : L("TAR 只打包不压缩，没有强度可调"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("更小"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 概览

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(L("用途"), value: options.matchingPurpose?.title ?? L("自定义"))
            Divider().padding(.leading, 12)
            summaryRow(L("格式"), value: "\(options.format.displayName) · .\(options.format.fileExtension)")
            Divider().padding(.leading, 12)
            summaryRow(L("强度"), value: levelSummary)
            Divider().padding(.leading, 12)
            summaryRow(
                L("文件名编码"),
                value: options.format.supportsUTF8Names
                    ? (options.forceUTF8Names ? L("UTF-8，Windows 解压不乱码") : L("跟随本机，老工具可能读错"))
                    : L("该格式无此设置")
            )
            Divider().padding(.leading, 12)
            summaryRow(
                L("分卷"),
                value: volumeSummary
            )
            Divider().padding(.leading, 12)
            summaryRow(L("实际参数"), value: options.argumentSummary().joined(separator: " "), monospaced: true)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var levelSummary: String {
        guard options.format.supportsLevel else { return L("不适用") }
        return "\(options.level.title) · -mx=\(options.level.mx)"
    }

    private var volumeSummary: String {
        guard options.format.supportsVolume else {
            return String(format: L("%@ 不支持分卷"), options.format.displayName)
        }
        guard let megabytes = options.volumeSize.megabytes(custom: options.customVolumeMB) else {
            return L("不分割")
        }
        return String(format: L("每卷 %d MB"), megabytes)
    }

    private func summaryRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 高级

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                ui.showAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ui.showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(L("高级"))
                        .font(.system(size: 12.5, weight: .medium))
                    if !ui.showAdvanced {
                        Text(advancedHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if ui.showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    toggleRow(
                        L("排除 macOS 辅助文件"),
                        note: L("__MACOSX、.DS_Store、._* 这些在别的系统上只是噪音"),
                        isOn: $options.excludeMacResources,
                        enabled: true
                    )
                    toggleRow(
                        L("排除 Windows 辅助文件"),
                        note: L("Thumbs.db、desktop.ini，通常没必要传给别人"),
                        isOn: $options.excludesWindowsJunk,
                        enabled: true
                    )
                    toggleRow(
                        L("标记文件名为 UTF-8"),
                        note: options.format.supportsUTF8Names
                            ? L("关掉后 Windows 自带解压器读中文名可能出错")
                            : L("只有 ZIP 有这个标记位"),
                        isOn: $options.forceUTF8Names,
                        enabled: options.format.supportsUTF8Names
                    )

                    Divider()

                    volumeRow
                    passwordSection
                }
                .padding(.top, 12)
                .padding(.leading, 2)
            }
        }
    }

    private var advancedHint: String {
        var parts = [L("排除辅助文件、分卷、密码")]
        if !options.password.isEmpty { parts.append(L("已设密码")) }
        if options.volumeSize != .none { parts.append(volumeSummary) }
        return parts.joined(separator: " · ")
    }

    private var volumeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("分卷大小"))
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                Picker("", selection: $options.volumeSize) {
                    ForEach(VolumeSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .disabled(!options.format.supportsVolume)
            }

            if options.volumeSize == .custom {
                HStack(spacing: 8) {
                    Text(L("每卷"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField("", value: $options.customVolumeMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text(L("MB"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Stepper("", value: $options.customVolumeMB, in: 1...102400, step: 50)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
            }

            Text(options.format.supportsVolume
                 ? L("产物是 xxx.001、xxx.002……，解压时选第一卷即可，7-Zip 与 Windows 都能自动续上后续卷。")
                 : String(format: L("%@ 无法分卷：单流压缩没有可切的索引。换成 ZIP 或 7Z 再试。"), options.format.displayName))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("密码"))
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
                if !options.format.supportsPassword {
                    Text(String(format: L("%@ 不支持加密"), options.format.displayName))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if options.format.supportsPassword {
                HStack(spacing: 8) {
                    SecureField(L("密码"), text: $options.password)
                        .textFieldStyle(.roundedBorder)
                    SecureField(L("确认密码"), text: $options.passwordRepeat)
                        .textFieldStyle(.roundedBorder)
                }

                if let mismatch = options.passwordValidationMessage {
                    Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                } else if options.password.isEmpty {
                    Text(L("密码只保留在本次运行中，不会写入磁盘。"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                if options.format.offersAESChoice {
                    Toggle(L("使用 AES-256 加密"), isOn: $options.zipAES256)
                        .disabled(options.password.isEmpty)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func toggleRow(_ title: String, note: String, isOn: Binding<Bool>, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!enabled)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if let mismatch = options.passwordValidationMessage {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                Text(L("下一步选要压缩的文件，再选保存位置。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(L("取消")) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(L("选择内容并压缩…")) { onConfirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(options.passwordValidationMessage != nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func sectionTitle(_ text: String, note: String?) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    #if DEBUG
    /// 仅调试：`ImageRenderer` 不渲染 `ScrollView` 的内容，这里给一个直排版，
    /// 让离屏截图能看到真实布局。参数与正式界面完全一致。
    func debugStraightLayout() -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            sections
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(width: 700)
    }
    #endif
}

/// 向导内部的展开状态，同样为了绕开 @State 宏。
private final class WizardState: ObservableObject {
    @Published var showAdvanced: Bool

    init() {
        #if DEBUG
        showAdvanced = ProcessInfo.processInfo.environment["THREXO_WIZARD_ADVANCED"] == "1"
        #else
        showAdvanced = false
        #endif
    }
}

/// 一张用途卡。
private struct PurposeCard: View {    let purpose: CompressionPurpose
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: purpose.symbolName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(purpose.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(purpose.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected
                          ? Color.accentColor.opacity(0.12)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
/// 仅调试：把向导离屏渲染成 PNG，用于在没有界面（锁屏、CI）时核对布局。
/// `THREXO_RENDER_WIZARD=/tmp/wizard.png` 启动即渲染并退出。
@MainActor
func renderWizardPreview(to path: String) {
    let wizard = CompressWizardView(
        options: CompressionOptions.shared,
        onCancel: {},
        onConfirm: {}
    )

    let renderer = ImageRenderer(content: wizard.debugStraightLayout())
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
}
#endif

