# 千梭 Threxo

> 把「解压」这件事做快、做少、做顺手。

千梭是一款 macOS 归档工具，原生 Swift / SwiftUI 实现，归档引擎是随包内置的 7-Zip（`7zz`）。
MVP 的核心只有一个动作：**在访达里右键，一项解压或压缩。**

当前版本号含义：「千梭」取织机上的梭子——往返极快、一路穿行、不留多余动作。

---

## 它做什么

- **访达右键**：无论选中什么，菜单里只有一项。
  - 选中的全是归档 → 「用千梭解压」（多选时显示「解压 N 个归档」）
  - 其他情况（普通文件、文件夹、混合选择）→ 「用千梭压缩」（显示「压缩 N 项」）
- **主窗口**：拖入压缩包查看内容树，支持选择性解压；拖入文件或文件夹直接打包。
- **双击接管**：双击归档、拖到 Dock 图标、`open -a Threxo` 均可打开。
- **不覆盖**：解压目标重名时自动追加序号（`解压结果`、`解压结果 2`…）；压缩同名时自动生成 `a.zip`、`a 2.zip`、`a 3.zip`，不静默删旧文件。

## 当前能力与边界

已实现并验证：

| 能力 | 说明 |
| --- | --- |
| 归档浏览 | `7zz l -slt` 解析，文件夹优先 + 本地化排序 |
| 全量解压 | 解到同级同名文件夹，自动去重 |
| 选择性解压 | 只落盘选中条目 |
| 选择目标解压 | 「解压到…」自选目录 |
| 压缩 | 文件与文件夹打包为 ZIP |
| 进度与取消 | 解析 `7zz` 百分比输出，可中途取消进程 |
| 错误提示 | 退出码映射为中文提示 |

尚未实现（已知缺口）：

- **并发批量处理**：多选 N 个归档时逐个处理，未做并行与进度聚合。
- **设置界面**：主窗口只在扩展未启用时给出橙色提示条和「前往设置」按钮，没有独立设置页与开关。
- **压缩参数**：固定档位，未暴露压缩级别、密码、分卷。
- **其他格式写入**：目前只输出 ZIP，`7z`/`tar` 等仅支持读取解压。

实测性能（本机 Apple Silicon，Debug 构建）：300 MB 归档解压约 **0.57 s**，压缩（`-mx=1`）约 6.0 s，解压结果与原文件逐字节一致。

## 目录结构

```
.
├── Threxo/                          Xcode 工程
│   ├── Threxo.xcodeproj
│   ├── Threxo/                      主 App（com.qujunxian.Threxo）
│   │   ├── ThrexoApp.swift          入口、菜单命令、URL Scheme
│   │   ├── ContentView.swift        主界面
│   │   ├── AppModel.swift           状态机：打开/解压/压缩/接收 URL
│   │   ├── Core/
│   │   │   ├── SevenZipRunner.swift  7zz 进程封装、进度与错误解析
│   │   │   ├── ArchiveLister.swift   `l -slt` 输出解析与目录树
│   │   │   └── PathValidator.swift   解压路径越界校验
│   │   └── Resources/               7zz（Universal 2）、许可、第三方声明
│   └── ThrexoFinder/                Finder Sync 扩展（com.qujunxian.Threxo.Finder）
├── M0/                              M0 技术验证（SwiftPM 命令行工具 + 验证报告）
├── 千梭-PRD-v1.1.md                 产品需求文档
├── ArcZip_REA分析.md                竞品逆向分析
└── REA研究/REA-深度调研报告.md       方法论与调研底稿
```

`M0/` 是立项前的可行性验证：接 `7zz`、解析进度、列表解析、路径校验全部在命令行侧跑通后，才落到 GUI 工程里。它保留作证据，不参与 App 构建。

## 构建

要求：macOS 14.0+、Xcode 15 以上。

```bash
open Threxo/Threxo.xcodeproj
# 或命令行
xcodebuild -project Threxo/Threxo.xcodeproj -scheme Threxo -configuration Debug build
```

签名使用自动签名。工程里 `DEVELOPMENT_TEAM` 写的是开发者本人的 Team ID，**换机器后需要在两个 target 的 Signing & Capabilities 里改成自己的 Team**，否则无法构建。

`7zz` 以二进制形式随包提交（`Threxo/Threxo/Resources/7zz`，7-Zip 26.04，x86_64 + arm64）。工程里有一条 Run Script 在构建时给它补 `chmod +x` 与 hardened runtime 重签，因为嵌套的可执行文件不重签会直接被 Gatekeeper 拦掉。

## 启用访达扩展

首次运行后：

1. 打开「系统设置 → 通用 → 登录项与扩展 → 访达」；
2. 打开「千梭」；
3. 主窗口橙色提示条会自动消失，右键菜单即可用。

如果扩展在列表里「已安装」但没有开关，通常是 LaunchServices 残留了同 Bundle ID 的旧路径（例如废纸篓里的旧构建）。清理：

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <旧 .app 路径>
killall pkd
```

工程里 `ThrexoFinder/Info.plist` 的 `LSUIElement = true` 与 `NSPrincipalClass = NSApplication` 不能删，缺任一项扩展都只会显示为「已安装」而不出现开关。

## 架构要点

- **App 不沙盒，扩展沙盒**。扩展需要 `user-selected.read-only`；App 侧要写任意目录，未开沙盒。
- **扩展不干活，只传话**。`FIFinderSync` 只负责组菜单，点击后拼 `threxo://extract|compress?path=...` 交给主 App。选中态在菜单点击时可能已经失效，所以菜单构建时就把 URL 记进 `Pending`。
- **进度靠文本解析**。`7zz` 的 `-bsp1` 是覆盖式输出，同一块里可能出现多个百分比，取最后一个；成功结束时 UI 补到 100，不依赖 `7zz` 输出。
- **路径安全**。解压前用 `PathValidator` 校验条目路径不越出目标目录，防 `../` 逃逸。

## 第三方与许可

- 归档引擎：[7-Zip](https://www.7-zip.org/)（`7zz` 26.04），遵循 7-Zip License，全文见 `Threxo/Threxo/Resources/7zip-License.txt`。
- 7-Zip 内含 unRAR 代码，其分发限制已在 `THIRD_PARTY_NOTICES.md` 说明。
- 本仓库代码暂未附开源许可文件。

## 文档

| 文档 | 内容 |
| --- | --- |
| `千梭-PRD-v1.1.md` | 15 章 MVP 需求：范围、命令映射、模块划分、RTM、风险登记 |
| `ArcZip_REA分析.md` | 竞品 ArcZip 的逆向分析，含证据分级与法律边界 |
| `REA研究/REA-深度调研报告.md` | 调研方法与底稿 |
| `M0/M0-验证报告.md` | M0 技术验证结论（7/7 通过） |
