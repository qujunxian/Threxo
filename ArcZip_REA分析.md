# ArcZip REA 深度分析报告

> 副标题：基于开源 7-Zip 引擎，复刻一款 macOS 解压缩 App 的可行性研究  
> 调研对象：ArcZip 1.1.5 (273) · <https://arczip.app>  
> 取证来源：从官方 DMG（`ArcZip-1.1.5-273.dmg`）只读挂载后逆向分析 App Bundle  
> 日期：2026-10-30



---

## 0. 摘要（Executive Summary）

| 维度   | 结论                                                                                         |
| ---- | ------------------------------------------------------------------------------------------ |
| 产品定位 | 为 macOS 重新设计的"美观、易用、快速"的归档工具，主打 Mini 悬浮窗、Hover 预览、Flow 操作流、ArcZip Box                      |
| 技术栈  | **100% 原生 Swift / SwiftUI + AppKit**，非 Electron/跨端；Universal 2（x86_64 + arm64），最低 macOS 14 |
| 压缩引擎 | **官方 7-Zip `7zz` v26.04**（作为独立可执行文件打包进 Bundle，以子进程方式调用）                                    |
| 辅助库  | ZIPFoundation（Swift，MIT，ZIP 读写/预览）、libarchive（部分格式预览）、Sparkle 2.9.4（自动更新）、Inter 字体（OFL）    |
| 系统扩展 | FinderSync（右键菜单）、QuickLook（空格预览）、XPC Service（沙箱化的归档核心进程）                                   |
| 授权模式 | 免费版（日常够用）+ Pro 一次性买断（非订阅），1 设备 / 3 设备两档                                                    |
| 引擎授权 | 7-Zip 为 **LGPL + unRAR 限制 + BSD**，可免费再分发（需附带许可证文本，ArcZip 已合规附带）                            |

### 三条最重要的结论

1. **"7-Zip 没有 Mac 版本"这个前提已经过时。** 官方 7-Zip 自 24.x 起已提供 macOS 命令行版（`7zz`，arm64/x86-64），ArcZip 打包的正是这个官方二进制。你的复刻思路（基于开源 7zip）不仅成立，而且已经被 ArcZip 验证可行——**最佳路径是用官方 `7zz`，而不是老的、已停更的 p7zip**。
2. **ArcZip 的"内核"是 7-Zip 的 C++ 代码，App 本身只是编排层。** 真正的压缩/解压能力来自 `7zz` 子进程，Swift 代码负责 UI、调度、沙箱、预览、安全校验。这意味着复刻的难点不在算法，而在**工程整合与体验打磨**。
3. **授权完全合规可行。** 以"独立可执行文件"方式打包 `7zz`（不静态链接）即满足 LGPL；RAR 仅做解压（不创建）即满足 unRAR 限制。ZIPFoundation/Sparkle/Inter 均为宽松许可证。

---

## 1. R — Research（产品调研）

### 1.1 产品定位与价值主张

- 标语：**"Archive tools, reimagined for macOS"** / "A better archive app. Beautifully designed. Easy to use. Built for speed."
- 核心叙事：从"打开压缩包"到"下一步操作"的每一步都自然流畅——完整工作区 + 便捷的 Mini 悬浮窗 + Flow 操作流。
- 目标人群：厌倦系统自带"归档实用工具"（Archive Utility）简陋体验、又不想被订阅制绑架的 Mac 用户。

### 1.2 功能矩阵（Free vs Pro）

| 功能                         | Free | Pro |
| -------------------------- | ---- | --- |
| 打开/浏览/解压全部支持格式             | ✅    | ✅   |
| 选择性 / 拖拽解压                 | ✅    | ✅   |
| ArcZip Mini 悬浮窗            | ✅    | ✅   |
| 部分 ArcZip Box 功能           | ✅    | ✅   |
| 空格键 Quick Look 预览          | ✅    | ✅   |
| 浏览嵌套压缩包                    | ✅    | ✅   |
| 创建标准 ZIP                   | ✅    | ✅   |
| Hover 预览（悬停看图/文档）          | ❌    | ✅   |
| 全部 Flow 动作（一键装 App/字体）     | ❌    | ✅   |
| 全部 ArcZip Box 功能           | ❌    | ✅   |
| 压缩包内搜索                     | ❌    | ✅   |
| 编辑已有压缩包                    | ❌    | ✅   |
| 全部压缩选项（含"发给 Windows 用户"预设） | ❌    | ✅   |
| 加密 / 分卷压缩包                 | ❌    | ✅   |

### 1.3 支持的格式（30+）

- **可创建/编辑**：ZIP/ZIPX（加密·分卷）、7Z（头加密）、TAR 系列（.tar/.tgz/.tbz2/.txz…）
- **只读（浏览/解压）**：RAR4/RAR5（分卷·加密）、单文件压缩（.gz/.bz2/.xz/.lzma/.lz）、DMG/ISO、软件包格式（.cab/.pkg/.xar/.rpm/.msi/.cpio/.lzh/.arj）、SWF（CWS/ZWS 转 FWS）
- 注：RAR **只能解不能建**（受 unRAR 许可证限制，所有合规产品都一样）。

### 1.4 商业模式

- **一次性买断，无订阅续费**；未来公开的大版本更新包含在内。
- 两档：1 设备 / 3 设备。价格页为动态加载（"Loading price"），需运行时抓取，公开页未固化。
- 免费版无广告、无水印——降低下载门槛，靠 Pro 转化。

### 1.5 竞品格局（Mac 解压赛道）

| 产品                 | 引擎/技术                | 授权           | 特色                   | 短板               |
| ------------------ | -------------------- | ------------ | -------------------- | ---------------- |
| **Keka**           | 自有（p7zip/libarchive） | 商店收费 / 商店外免费 | 轻量、加密、分卷、邮件集成        | 无包内预览、拖出解压、多任务并行 |
| **BetterZip**      | 自有                   | $24.95       | 30+ 格式、AES-256、预览、编辑 | 收费、无多文件并行        |
| **The Unarchiver** | 自有（Objective-C）      | 免费           | 文件名编码修复强、极简          | 无预览/部分解压/无压缩     |
| **eZip**           | 自有                   | 免费           | 预览、编辑、空格预览           | 功能中等             |
| **MacZip**         | 自有                   | 商店收费 / 商店外免费 | 预览/编辑/拖出/部分解压/加密/分卷  | 无多包并行、右键需手动配置    |
| **Bandizip**       | 自有                   | Mac 版收费      | Windows 经典           | Mac 收费不香         |
| **Commander One**  | 双栏文件管理器+归档           | 收费           | FTP/SFTP、包内搜索编辑      | 重、非纯解压           |
| **WinZip**         | 自有                   | 免费+Pro       | 云盘集成                 | 性价比一般            |

**ArcZip 的差异化**：把"解压"做成**工作流产品**而非单纯工具——Mini 悬浮、Hover 预览、Flow 动作、Box 收纳、跨平台兼容性预设，且强调**安全设计**（路径遍历防护、暂存区、独立进程）。这是它相对 Keka/BetterZip 的体验升维。

### 1.6 差异化亮点拆解

- **ArcZip Mini**：跟随指针的紧凑窗口，就近浏览/选择/解压，随时切到完整工作区。
- **Hover Preview**：悬停图片/文档即显示预览，无需先解压。
- **Flow actions**：根据所选文件智能给出"下一步"（解压/装 App/装字体）。
- **ArcZip Box**：把待处理文件拖入，统一查看/压缩/拖出发送。
- **Purpose presets**：发 Windows 用户时检查文件名兼容性、过滤 macOS 辅助文件；Linux/服务器预设保留元数据。
- **安全设计（重点）**：路径遍历/绝对路径/命名冲突/危险类型校验；压缩解压先写入同盘私有暂存区，失败/取消保护原件并清理；归档解析与核心操作跑在**独立 XPC 服务**中，Finder 请求短生命周期、仅可用一次。

---

## 2. E — Engineering（工程拆解，基于 DMG 逆向）

### 2.1 逆向证据清单（从 DMG 提取的硬事实）

| 项目        | 证据                                                                                                     |
| --------- | ------------------------------------------------------------------------------------------------------ |
| Bundle ID | `com.maczhang.ArcZip`（开发者代号 maczhang）                                                                  |
| 版本        | 1.1.5 (273)，构建 SDK `macosx27.0`，最低系统 `LSMinimumSystemVersion=14.0`                                     |
| 主程序       | `MacOS/ArcZip` = **Universal 2**（x86_64 + arm64），27.3 MB                                               |
| 压缩引擎      | `Resources/7zz` = **Universal 2**，运行显示 `7-Zip (z) 26.04 (arm64) : Copyright (c) 1999-2026 Igor Pavlov` |
| 引擎许可证     | `Resources/7zip-License.txt`：LGPL 主许可 + unRAR 限制 + BSD-3 + BSD-2                                       |
| ZIP 库     | `Resources/THIRD_PARTY_NOTICES.md`：ZIPFoundation 0.9.20（MIT）                                           |
| 自动更新      | `Frameworks/Sparkle.framework`（Sparkle 2.9.4，MIT）                                                      |
| 系统扩展      | `PlugIns/ArcZipFinderSync.appex`（右键菜单）、`PlugIns/ArcZipQuickLook.appex`（空格预览）                           |
| 沙箱核心      | `XPCServices/ArcZipArchiveService.xpc`（Universal 2）——独立归档服务进程                                          |
| 字体        | `Resources/Inter-Bold.otf`（OFL）                                                                        |
| 资源        | `Assets.car`（编译后的资源目录）、多语言 `en/zh-Hans/zh-Hant.lproj`                                                  |

### 2.2 技术架构总览

```
┌──────────────────────────────────────────────────────────┐
│  ArcZip.app (SwiftUI App, Universal 2)                     │
│  ├─ UI 层：工作区 / Mini 悬浮窗 / Hover 预览 / Flow / Box    │
│  ├─ 编排层：任务调度、进度解析、安全校验、格式路由            │
│  └─ 引擎调用：NSTask 子进程调用 Resources/7zz               │
└───────────────┬───────────────────────────┬───────────────┘
                │ XPC（沙箱隔离、版本化通信） │
                ▼                            ▼
   ArcZipArchiveService.xpc        FinderSync.appex   QuickLook.appex
   （归档解析/核心操作）            （右键菜单）       （空格预览）
                │
                ▼
   Resources/7zz（官方 7-Zip 26.04）
   + ZIPFoundation（ZIP 读写/预览）
   + libarchive（部分格式预览引擎）
```

- **UI/编排**用 SwiftUI（二进制符号含 `SwiftUI3AppP`、`SwiftUI11ButtonStyleP`、`NSViewRepresentableP` 表明混用 AppKit 自定义视图）。
- **核心能力下沉到 XPC 服务**：主 App 不直接碰归档 I/O，降低提权/崩溃面，满足"Separate processing"安全主张。
- **引擎是外部子进程**：`7zz` 既不被静态链接，也不进主二进制，天然满足 LGPL。

### 2.3 压缩引擎：官方 7-Zip `7zz`

- 从二进制字符串可看到调用痕迹：`official-7zip`（引擎标识）、`phase=7zz_first_progress`（进度上报）、`7zip-deflate-level-`（压缩级别开关）。
- 推断调用模型（基于 7-Zip 命令行惯例）：
  - 解压：`7zz x archive.7z -o<outdir> -p<pass> -y`
  - 压缩：`7zz a out.7z <files> -mx=<level> -mmt=on -p<pass> -mhe=on`
  - 分卷：`7zz a out.zip -v100m <files>`
  - 进度：解析 `7zz` 的 stdout（百分比/文件名），通过 XPC 回传主 App。
- 关键工程点：**进度解析 + 取消信号传递 + 错误码映射**（401/路径遍历/密码错误）是体验关键，ArcZip 显然做了大量封装。

### 2.4 辅助库

- **ZIPFoundation（Swift/MIT）**：原生 ZIP 读写，用于**无需调用 7zz 的轻量场景**（如 Quick Look 预览、快速列目录），提升响应速度、减少子进程开销。
- **libarchive**（二进制含 `system-libarchive`、`LibarchivePreviewEngine` 符号）：用于部分格式的**预览引擎**，与 7zz 形成"重操作靠 7zz、轻预览靠 libarchive/ZIPFoundation"的双引擎策略。
- **Sparkle 2.9.4**：独立更新通道（绕过 App Store，避免 30% 分成与沙箱限制，也解释了为何 DMG 直接分发）。

### 2.5 系统扩展（Mac 体验的关键）

| 扩展          | 作用                    | 复刻必要性                   |
| ----------- | --------------------- | ----------------------- |
| FinderSync  | 右键上下文菜单（解压到…/压缩…）     | 高（用户最常用入口）              |
| QuickLook   | 在 Finder 选中压缩包按空格预览内容 | 高（"空格预览"是卖点）            |
| XPC Service | 沙箱内归档核心进程             | 中高（安全+稳定性，MVP 可先用子进程直调） |

### 2.6 安全设计拆解（值得复刻的部分）

1. **路径穿越防护**：校验绝对路径、`./`、`../`、命名冲突、危险文件类型（如 `.app`/脚本），写入限定在受控目录。
2. **暂存区（Staging）**：压缩/解压先落到同盘私有暂存区，失败或取消则保护原件并清理半成品——避免半截文件污染用户目录。
3. **进程隔离**：归档解析与核心操作在独立、版本化通信、已验证连接的 XPC 服务中；Finder 请求短生命周期、一次性。
4. **不传云端**：明确声明文件与密码不上传（隐私卖点，也是合规底线）。

### 2.7 UI 技术栈

- SwiftUI App 生命周期（`@main App`），关键交互视图用 `NSViewRepresentable` 桥接 AppKit（如自定义列表/缩略图视图）。
- 资源用 Assets.car（Xcode 资源目录），多语言本地化（中简/中繁/英）。
- 字体用开源 Inter，保证跨平台视觉一致。

### 2.8 自动更新

- Sparkle 2.9.4，DMG 直分发的标配。需在自有服务器托管 `appcast.xml` 与增量更新。

---

## 3. A — Analysis（复刻可行性分析与建议）

### 3.1 技术可行性：结论 = 高度可行

- 引擎（7zz）、预览库（ZIPFoundation/libarchive）、更新（Sparkle）、扩展（FinderSync/QuickLook/XPC）全部是**成熟开源/原生组件**，ArcZip 已证明其组合可行。
- 真正的壁垒是**工程整合与体验打磨**（进度、取消、错误映射、安全校验、Hover 预览、Flow 智能动作），而非算法。

### 3.2 ⚠️ 关于"7zip 无 Mac 版本"的澄清（重要）

- **官方 7-Zip 已有 macOS 版**：7-zip.org 下载页明确列出 `macOS (arm64 / x86-64) 7-Zip for MacOS: console version`（`7z2605-mac.tar.xz` 等），提供 `7zz` 命令行二进制。ArcZip 打包的正是官方 `7zz` 26.04。
- **不要用老的 p7zip**：p7zip 是第三方维护、版本滞后、部分格式支持不全且基本停更。
- **建议**：直接采用官方 `7zz`（或自行从 7-Zip 源码为 macOS 编译），与 ArcZip 同路，兼容性/性能最佳。

### 3.3 授权与合规（可放心复刻）

| 组件            | 许可证                   | 复刻注意点                                                    |
| ------------- | --------------------- | -------------------------------------------------------- |
| 7-Zip (`7zz`) | LGPL + unRAR 限制 + BSD | 以**独立可执行文件**分发（不静态链接）；附带 `7zip-License.txt`；RAR **只解不建** |
| ZIPFoundation | MIT                   | 保留版权声明即可                                                 |
| Sparkle       | MIT                   | 保留声明                                                     |
| Inter 字体      | OFL                   | 可自由使用/再分发                                                |
| libarchive    | BSD                   | 保留声明                                                     |

> 关键：把 `7zz` 当独立二进制打包 = 干净 LGPL 合规（ArcZip 即此做法）。若未来想静态链接 7-Zip 代码，则需向用户开放相应源码——初期没必要。

### 3.4 开发路线图（建议分期）

**Phase 0 — 技术验证（1–2 周）**

- 在 macOS 上跑通官方 `7zz`：解压/压缩/加密/分卷/进度解析的命令行样板。
- 确认 Xcode + SwiftUI 基础工程，目标 macOS 14+，Universal 2。

**Phase 1 — MVP（Free 核心，4–6 周）**

- 主工作区：打开压缩包 → 树/列表/缩略图视图。
- 解压（全量 + 选择性 + 拖拽）、创建标准 ZIP。
- 调用 `7zz` 子进程 + 进度/取消/错误映射。
- 基础安全校验（路径穿越、绝对路径）。

**Phase 2 — 体验升维（Pro 前身，6–10 周）**

- FinderSync 右键菜单、QuickLook 空格预览。
- Hover 预览、压缩包内搜索、编辑已有包。
- 加密/分卷、Purpose presets（Windows/Linux 兼容）。
- XPC 服务化（沙箱隔离）、暂存区机制。

**Phase 3 — 商业化与打磨（持续）**

- Sparkle 更新通道 + 自建 appcast。
- 一次性买断激活（License 校验），Free/Pro 功能开关。
- Mini 悬浮窗、Flow 动作、ArcZip Box（差异化护城河）。

### 3.5 风险与坑

1. **技术栈切换成本**：你是 Java 后端背景，而 ArcZip 是 Swift/SwiftUI 原生 Mac 开发。需补齐 Swift + AppKit + Xcode + 沙箱/Mac 系统扩展知识。可考虑先外包/协作或系统学习。
2. **Finder 扩展沙箱**：FinderSync/QuickLook 受沙箱与用户授权约束，调试链路长。
3. **RAR 法律红线**：任何产品都**不能**用 7-Zip 代码创建 RAR（unRAR 限制），只能解压——需在 UI 上明确禁用"创建 RAR"。
4. **性能与进度**：大包（如 23 万文件级）的目录枚举、进度平滑、取消响应是体验分水岭，需参考你既有的多线程/批量优化经验（NspmNatInfoReader 的线程池经验可迁移到 7zz 的 `-mmt` 多线与分块调用）。
5. **App Store vs DMG 直发**：上架 Mac App Store 会强制沙箱、限制 XPC/Helper，且 30% 分成；ArcZip 选择 DMG+Sparkle 直发。你也要尽早定渠道。

### 3.6 给曲工的具体建议

- **引擎**：立刻下载官方 `7zz` 在本地验证，把它作为唯一压缩内核，放弃 p7zip。
- **语言/框架**：接受"原生 Swift/SwiftUI"是这条赛道的事实标准（竞品 Keka/BetterZip 全是原生）。若团队无 Swift 能力，最务实的折中是 **Tauri（Rust 壳 + WebView UI）+ 原生 Swift 插件做 FinderSync/QuickLook/XPC**——但核心扩展仍逃不开 Swift。
- **先做"能用的解压器"再谈"体验"**：MVP 阶段把 7zz 子进程封装稳，再叠加 Mini/Hover/Flow 等差异化。
- **合规前置**：从第一行代码就把 `7zip-License.txt` 和第三方声明打进 Bundle，避免后期返工。
- **借力你现有能力**：高吞吐/多线程/批量写入的工程经验，正好用于优化"大压缩包并发解压 + 进度上报"，这是和竞品拉开差距的切入点。

---

## 4. 研究方法与证据分级（REA 方法论落地）

> 本节并入 iMA 文档《REA（Reverse Engineer Anything）深度调研报告》的方法论。其核心理念是「把『我猜』变成『我看到了证据』」：每条结论 = 产物身份 + 源位置 + 观测 + 推断 + 未决发现；不编造百分比，证据矛盾即 fail-closed 停止。

### 4.1 本次分析的证据链

- **分析对象**：用户提供的官方安装包 `ArcZip-1.1.5-273.dmg`，**只读挂载**，未运行主程序、未修改任何文件。
- **证据来源**：Bundle 目录结构、`Info.plist`、二进制文件类型（`file` / `strings`）、`7zz` 运行版本、`THIRD_PARTY_NOTICES.md`、许可证文本。
- **结论生成规则**：文件里能直接看到的 → 观测；按 7-Zip 惯例推测的 → 推断；静态分析无法确认的 → 未知（不臆造）。

### 4.2 证据分级表

| 结论 | 类型 | 证据 / 依据 | 置信度 |
|---|---|---|---|
| 使用官方 7-Zip `7zz` 26.04 | 观测 | `Resources/7zz` 运行输出首行 | 高 |
| 全部二进制为 Universal 2 | 观测 | `file` 命令输出（x86_64 + arm64） | 高 |
| UI 为 SwiftUI + AppKit 混合 | 观测 | 二进制符号 `SwiftUI3AppP`、`NSViewRepresentableP` | 高 |
| 使用 ZIPFoundation 0.9.20 | 观测 | `THIRD_PARTY_NOTICES.md` 明示 | 高 |
| 使用 libarchive 做预览 | 观测(符号) + 推断(用途) | `system-libarchive`、`LibarchivePreviewEngine` | 中高 |
| XPC 承载归档核心操作 | 观测(存在) + 推断(职责) | `XPCServices/ArcZipArchiveService.xpc` | 中高 |
| 7zz 的具体命令行参数 | 推断 | `official-7zip`、`7zip-deflate-level-`、`phase=7zz_first_progress` + 7-Zip 惯例 | 中 |
| XPC 通信协议细节 | 未知 | 未反编译 | 低 |
| 定价具体数值 | 未知 | 官网动态加载，公开页未固化 | 低 |

### 4.3 证据缺口（待运行期验证）

1. `7zz` 实际调用参数与进度解析格式——建议用包装脚本记录 argv 与 stdout 实测。
2. XPC 协议（版本握手、消息格式、错误码）。
3. FinderSync 菜单项的实际文案与多选时的行为。
4. 加密压缩的具体算法参数（AES-256？`-mhe=on`？）。
5. 大包场景的并发/分块策略（单进程 `-mmt` 还是多进程分片）。

> 按 REA 原则，以上缺口**不猜**，直接用官方 7-Zip 文档 + 黑盒实验确定；复刻时每个功能都应留下可复核证据（命令、输出、截图）。

### 4.4 法律与合规边界（引用 REA 报告 §8）

- 本分析仅针对用户提供的、用于**学习与互操作**目的的公开安装包做**静态结构观察**；未破解授权、未绕过签名、未提取受版权保护的资源用于再分发。
- REA 报告明确：逆向仅用于合法研究、教育、互操作、软件保存，以及你拥有或获授权的软件；各地法律不同（美 DMCA §1201(f)、欧盟 2009/24/EC 第 6 条有互操作例外）。
- 复刻产品应**独立实现**，只借鉴通用交互模式与架构思路，不复制 ArcZip 的文案、图标、视觉资源与专有代码。

---

## 附录：DMG 逆向取证原始数据

- 镜像：`ArcZip-1.1.5-273.dmg`，lzfse 压缩 UDIF 只读，APFS 分区，32.8 MB。
- 挂载方式：只读、nobrowse（未改动任何文件）。
- 关键文件大小：主程序 27.3 MB；`7zz` 6.1 MB；`Assets.car` 3.9 MB；`THIRD_PARTY_NOTICES.md` 51 KB；`7zip-License.txt` 6 KB。
- 全部二进制（主程序 / 7zz / XPC / FinderSync / QuickLook）均为 Universal 2（x86_64 + arm64）。
- `7zz` 运行输出首行：`7-Zip (z) 26.04 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-10-05`。

> 说明：已在 v1.1 并入本地 iMA 文档《REA（Reverse Engineer Anything）深度调研报告》的方法论（见第 4 章）。该文档讲的是「证据驱动逆向」的工具与流程，本文档据此把结论区分为**观测 / 推断 / 未知**三档，并列出待运行期验证的证据缺口，避免把推测当事实。下一步的产品需求见同目录 `千梭-PRD-v1.1.md`（产品定名「千梭 / Threxo」，技术栈锁定原生 Swift/SwiftUI；M0 技术验证 7/7 通过，见 `M0/M0-验证报告.md`）。
