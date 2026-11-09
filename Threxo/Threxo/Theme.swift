import SwiftUI
import AppKit
import Combine

// MARK: - 主题数据

/// 界面所有按钮、图标、颜色与尺寸的唯一来源。
///
/// 之前解压页 / 压缩页各自手写 `Color.accentColor`、`Color.purple`、`Color.red`、
/// 11.5pt / 12.5pt / 13pt 混用，同一排按钮看起来像两套 App。现在把「度量 + 配色」
/// 收成一个值类型，视图只消费主题，不许再写死颜色与字号。
///
/// 扩展方式：`ThemeStore.shared.register(自定义主题)` → `select(id:)`。
/// 也可以用 `.appTheme(某个主题)` 在任意子视图上局部覆盖。
struct AppTheme {
    let id: String
    let displayName: String

    // 色彩（动态色会跟随浅色 / 深色自动切换）
    let accent: Color
    let primaryStart: Color
    let primaryEnd: Color
    let primaryForeground: Color
    let primaryShadow: Color
    let pillBackground: Color
    let pillBorder: Color
    let surface: Color
    let surfaceBorder: Color
    let icon: Color
    let iconSecondary: Color
    let danger: Color
    let pressedOverlay: Color
    let shortcutChip: Color

    // 度量
    let symbolSize: CGFloat
    let symbolWeight: Font.Weight
    let barFont: CGFloat
    let barSymbolSize: CGFloat
    let controlHeight: CGFloat
    let primaryHeight: CGFloat
    let iconButtonSize: CGFloat
    let cornerRadius: CGFloat
    let primaryHorizontalPadding: CGFloat
    let compactBreakpoint: CGFloat

    var primaryGradient: LinearGradient {
        LinearGradient(colors: [primaryStart, primaryEnd], startPoint: .top, endPoint: .bottom)
    }
}

extension AppTheme {
    /// v1.1 默认主题：紫色主操作 + 中性胶囊工具条。
    /// 配色沿用现有视觉（不推倒重来），只把散落各处的写法收敛到一处。
    static let threxo = AppTheme(
        id: "threxo.default",
        displayName: "千梭紫",
        accent: Color.accentColor,
        primaryStart: Color(red: 0.62, green: 0.44, blue: 0.99),
        primaryEnd: Color(red: 0.52, green: 0.33, blue: 0.94),
        primaryForeground: .white,
        primaryShadow: Color.purple.opacity(0.22),
        pillBackground: Color(nsColor: .controlBackgroundColor),
        pillBorder: Color.primary.opacity(0.08),
        surface: Color(nsColor: .controlBackgroundColor),
        surfaceBorder: Color.primary.opacity(0.10),
        icon: Color.primary,
        iconSecondary: Color.secondary,
        danger: Color(red: 0.94, green: 0.30, blue: 0.31),
        pressedOverlay: Color.primary.opacity(0.10),
        shortcutChip: Color.primary.opacity(0.07),
        symbolSize: 12,
        symbolWeight: .medium,
        barFont: 11.5,
        barSymbolSize: 12,
        controlHeight: 26,
        primaryHeight: 34,
        iconButtonSize: 26,
        cornerRadius: 6,
        primaryHorizontalPadding: 22,
        // 底栏窄于此宽度时先收起状态文字与快捷键徽标，避免把按钮挤到重叠。
        // 压缩页开着 258pt 详情栏、窗口 880pt 时，底栏正好只剩 622pt，会命中这里。
        compactBreakpoint: 700
    )
}

// MARK: - 主题仓库（对外接口）

/// 主题注册与切换。当前只有一套默认主题，但接口已经留好：
/// 以后新增深色高对比、蓝色系等主题，注册后一行 `select` 即可全局生效。
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    private static let defaultsKey = "threxo.theme.id"

    @Published private(set) var theme: AppTheme
    @Published private(set) var available: [AppTheme]

    init() {
        let presets: [AppTheme] = [.threxo]
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppTheme.threxo.id
        self.available = presets
        self.theme = presets.first { $0.id == saved } ?? .threxo
    }

    /// 注册一套新主题。同 id 视为更新，不重复追加。
    func register(_ theme: AppTheme) {
        if let index = available.firstIndex(where: { $0.id == theme.id }) {
            available[index] = theme
            if self.theme.id == theme.id { self.theme = theme }
        } else {
            available.append(theme)
        }
    }

    func select(id: String) {
        guard let found = available.first(where: { $0.id == id }), found.id != theme.id else { return }
        theme = found
        UserDefaults.standard.set(id, forKey: Self.defaultsKey)
    }
}

// MARK: - Environment 注入

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .threxo
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    /// 局部覆盖主题（也可用于预览 / 调试某个候选主题）。
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
    }
}

/// 底栏宽度不足以容纳「图标 + 文字 + 状态」时，只保留图标。
private struct ActionBarCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var actionBarCompact: Bool {
        get { self[ActionBarCompactKey.self] }
        set { self[ActionBarCompactKey.self] = newValue }
    }
}

// MARK: - 统一图标 / 按钮

enum ThemeTone {
    case normal, secondary, accent, danger, onPrimary

    func color(_ theme: AppTheme) -> Color {
        switch self {
        case .normal: return theme.icon
        case .secondary: return theme.iconSecondary
        case .accent: return theme.accent
        case .danger: return theme.danger
        case .onPrimary: return theme.primaryForeground
        }
    }
}

/// 所有 SF Symbol 的统一入口：同一字号、字重、单色渲染。
/// 单色是关键——系统默认的分层 / 多色渲染会让同一排图标轻重不一。
struct ThemeIcon: View {
    @Environment(\.appTheme) private var theme

    let symbol: String
    var size: CGFloat? = nil
    var weight: Font.Weight? = nil
    var tone: ThemeTone = .normal

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size ?? theme.symbolSize, weight: weight ?? theme.symbolWeight))
            .foregroundStyle(tone.color(theme))
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
    }
}

/// 顶栏统一图标按钮：同一尺寸、同一圆角、同一描边 / 填充规则。
/// - `filled`：主操作或危险操作用实心；普通开关用中性底。
struct ThemeIconButton: View {
    @Environment(\.appTheme) private var theme

    let symbol: String
    var tone: ThemeTone = .normal
    var filled: Bool = false
    var isEnabled: Bool = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ThemeIcon(symbol: symbol, size: theme.barSymbolSize,
                      tone: filled ? .onPrimary : tone)
                .frame(width: theme.iconButtonSize, height: theme.iconButtonSize)
                .background(
                    Capsule().fill(background)
                )
                .overlay(Capsule().strokeBorder(border))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? "")
    }

    private var background: Color {
        guard isEnabled else { return theme.surface }
        if filled {
            return tone == .danger ? theme.danger : theme.accent
        }
        return theme.surface
    }

    private var border: Color {
        filled && isEnabled ? Color.clear : theme.surfaceBorder
    }
}

/// 两页共用的主操作按钮：压缩页「添加文件」、解压页「解压到…」、顶栏「保存」。
/// 统一渐变、高度、字号、阴影与禁用态。
struct PrimaryActionButton: View {
    @Environment(\.appTheme) private var theme

    let title: String
    let symbol: String
    /// 顶栏那种紧凑版本：矮一点、窄一点，但配色与主按钮完全同源。
    var compact: Bool = false
    var isEnabled: Bool = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ThemeIcon(symbol: symbol,
                          size: compact ? theme.barSymbolSize : theme.symbolSize,
                          weight: .semibold,
                          tone: .onPrimary)
                Text(title)
                    .font(.system(size: compact ? theme.barFont : 13, weight: .semibold))
            }
            .foregroundStyle(isEnabled ? theme.primaryForeground : theme.iconSecondary)
            .padding(.horizontal, compact ? 11 : theme.primaryHorizontalPadding)
            .frame(height: compact ? theme.controlHeight : theme.primaryHeight)
            .background(
                Capsule().fill(isEnabled ? AnyShapeStyle(theme.primaryGradient)
                                         : AnyShapeStyle(theme.surface))
            )
            .overlay(
                Capsule().strokeBorder(isEnabled ? Color.clear : theme.surfaceBorder)
            )
            .shadow(color: isEnabled ? theme.primaryShadow : Color.clear,
                    radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? title)
    }
}

/// 中性小胶囊（文件名、搜索框一类），统一圆角与描边。
struct ThemeSurface: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.pillBorder))
    }
}

extension View {
    func themeSurface() -> some View { modifier(ThemeSurface()) }
}
