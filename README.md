# 千梭 Threxo

> 把「解压」这件事做快、做少、做顺手。

千梭是一款 macOS 归档工具，原生 Swift / SwiftUI 实现，归档引擎是随包内置的 7-Zip（`7zz`）。
MVP 的核心只有一个动作：**在访达里右键，一项解压或压缩。**

当前版本号含义：「千梭」取织机上的梭子——往返极快、一路穿行、不留多余动作。

---

## 它做什么

- **访达右键**：无论选中什么，菜单里只有一项，而且**点了就走**——不打开主窗口、不问存哪里、不弹任何对话框。
  - 选中的全是归档 → 「用千梭解压」（多选时显示「解压 N 个归档」），内容直接解到压缩包所在文件夹
  - 其他情况（普通文件、文件夹、混合选择）→ 「用千梭压缩」（显示「压缩 N 项」），产物落在当前目录
  - 进度只在菜单栏显示（可取消）；**完成后发一条系统通知**（成功、失败都发），点通知直接在访达里定位产物
  - App 若是为这次任务才启动的，跑完自动退出；首次使用会请求一次「允许通知」授权
- **主窗口**：拖入压缩包查看内容树，像 WinRAR 那样直接在里面挑文件。
  - 选中条目 → 右键或底部按钮：解到同级文件夹 / 解到指定目录 / 解到压缩包所在文件夹
  - **把条目拖到访达**任意文件夹 = 松手即解压到那里（文件夹带整个子树）
  - **把文件拖进窗口** = 直接加进当前归档的对应层级（拖到文件夹行就进那一层，拖到空白处进根）
- **双击接管**：双击归档、拖到 Dock 图标、`open -a Threxo` 均可打开。
- **不覆盖**：解压目标重名时自动追加序号（`解压结果`、`解压结果 2`…）；压缩同名时自动生成 `a.zip`、`a 2.zip`、`a 3.zip`，不静默删旧文件。

## 当前能力与边界

已实现并验证：

| 能力 | 说明 |
| --- | --- |
| 归档浏览 | `7zz l -slt` 解析，文件夹优先 + 本地化排序 |
| 全量解压 | 窗口内解到同级同名文件夹、自动去重；右键直接解到当前文件夹（`-aou` 不覆盖） |
| 选择性解压 | 只落盘选中条目 |
| 选择目标解压 | 「解压到…」自选目录 |
| 解压到此处 | 直接解到压缩包所在文件夹，`-aou` 改名不覆盖 |
| 拖出解压 | 条目拖到访达任意位置，松手时才解压；文件夹带整个子树 |
| 拖入追加 | 文件拖到列表的文件夹行/空白处，写进归档对应层级；同名给「保留两者 / 覆盖 / 取消」 |
| 压缩 | 7 种格式可选，见下表 |
| 压缩级别 | 存储 / 快速 / 正常 / 慢速，映射 `-mx=0/1/5/9` |
| 密码加密 | zip 用 AES-256，7z 用 7zAES；解压时弹窗索要密码 |
| 排除 Mac 资源 | 剔除 `__MACOSX`、`.DS_Store`、`._*`（可关） |
| 压缩后删源文件 | 默认关闭；开启后仍需二次确认，**移到废纸篓**而非永久删除 |
| 压缩后自检 | 默认关闭；开启后追加 `7zz t` 逐项比对 CRC，失败则保留源文件并提示 |
| 进度与取消 | 解析 `7zz` 百分比输出，可中途取消进程 |
| 错误提示 | 退出码映射为可读提示 |
| 界面语言 | 中英双语，跟随系统语言；缺译文时自动回落中文 |

### 格式支持（照内置 7-Zip 26.04 实测）

| 格式 | 创建 | 压缩级别 | 密码 |
| --- | :---: | :---: | --- |
| ZIP | ✅ | ✅ | ✅ AES-256（`-mem=AES256`） |
| 7Z | ✅ | ✅ | ✅ 7zAES（AES-256） |
| TAR | ✅ | — | ❌ |
| GZIP / BZIP2 / XZ | ✅ | ✅ | ❌ |
| WIM | ✅ | ✅ | ❌ |
| RAR / DMG / ISO / CAB 等 | ❌ | — | 仅解压 |

有些第三方工具能选 ZSTD、LZ4、Brotli、LZIP、LRZIP、AAR、SNAPPY，那是 7-Zip ZS 分支才有的编解码器；官方 `7zz` 对它们返回 rc=2，因此**没有**放进产品——功能缺底层支持就不做，不做假开关。

两个实现细节：TAR 与 WIM 收到 `-p` 会被静默忽略（rc=0 但内容未加密），所以密码项对它们置灰；GZIP/BZIP2/XZ 只能压单个文件流，目录与多选会先打 tar 再压，产物是标准 `.tar.gz` / `.tar.bz2` / `.tar.xz`，解压时自动拆掉中间那层 tar。

尚未实现（已知缺口）：

- **并发批量处理**：多选 N 个归档时逐个处理，未做并行与进度聚合。
- **独立设置页**：压缩选项在顶栏设置浮层里，没有单独的系统设置面板。
- **分卷**：`7zz -v` 可用，但除了切分还要改归档识别（`.7z.001`）、解压目标命名、重名判断，且缺卷时 7zz 返回 0 必须自己兜底，暂不做。
- **RAR 写入**：7-Zip 不支持创建 RAR。

实测性能（本机 Apple Silicon，Debug 构建）：300 MB 归档解压约 **0.57 s**，压缩（`-mx=1`）约 6.0 s，解压结果与原文件逐字节一致。

## 目录结构

```
.
├── Threxo/                          Xcode 工程
│   ├── Threxo.xcodeproj
│   ├── Threxo/                      主 App（com.qujunxian.Threxo）
│   │   ├── ThrexoApp.swift          入口、菜单命令、URL Scheme
│   │   ├── ContentView.swift        主界面（格式选择器、设置浮层、密码框）
│   │   ├── CompressOptionsView.swift 压缩设置面板
│   │   ├── AppModel.swift           状态机：打开/解压/压缩/接收 URL
│   │   ├── Core/
│   │   │   ├── SevenZipRunner.swift  7zz 进程封装、进度与错误解析
│   │   │   ├── ArchiveLister.swift   `l -slt` 输出解析与目录树
│   │   │   ├── ArchiveEditing.swift  往已有归档追加文件（镜像目录 + 相对路径）
│   │   │   ├── ArchiveExport.swift   拖出到访达（落点时才解压）
│   │   │   ├── CompressionOptions.swift 格式/级别/密码/勾选项与持久化
│   │   │   └── PathValidator.swift   解压路径越界校验
│   │   ├── Assets.xcassets/         AppIcon（深蓝底 + 白梭 + 三道经线）
│   │   └── Resources/               7zz（Universal 2）、许可、第三方声明
│   └── ThrexoFinder/                Finder Sync 扩展（com.qujunxian.Threxo.Finder）
├── Tools/GenerateIcon.swift         图标绘制脚本（CoreGraphics 参数化生成）
├── M0/                              M0 技术验证（SwiftPM 命令行工具 + 验证报告）
└── 千梭-PRD-v1.2.md                 产品需求文档
```

`M0/` 是立项前的可行性验证：接 `7zz`、解析进度、列表解析、路径校验全部在命令行侧跑通后，才落到 GUI 工程里。它保留作证据，不参与 App 构建。

图标不用外部设计文件，`Tools/GenerateIcon.swift` 以参数方程直接绘制（超椭圆底板、船形梭子、胶囊经线）：

```bash
swift Tools/GenerateIcon.swift /tmp/icon-1024.png
```

生成 1024 主图后用 `sips` 缩出 10 个尺寸放进 `Assets.xcassets/AppIcon.appiconset/`。两个必须守住的约束：四周 100 px 留白区必须完全透明，且**不能在底板外画投影**——阴影一旦溢出留白，macOS 会把图标判定成旧式全出血图标，反过来再套一层灰白底板。

## 构建

要求：macOS 14.0+、Xcode 15 以上。

```bash
open Threxo/Threxo.xcodeproj
# 或命令行
xcodebuild -project Threxo/Threxo.xcodeproj -scheme Threxo -configuration Debug build
```

签名使用自动签名。工程里 `DEVELOPMENT_TEAM = T9DDF2YTVH`，对应证书 `Apple Development: qu18769592321@icloud.com (KNMDZMAWRG)`，两者已核实匹配。**换机器后需要在两个 target 的 Signing & Capabilities 里改成自己的 Team**，否则无法构建。

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
- **永远带 `-p`，但追加除外**。解压时不给 `-p`，`7zz` 会停下来等终端输入密码、进程直接卡死，所以无论有没有密码都传（空密码就是 `-p`）。但 `7zz a` 上的空 `-p` 语义是「去问用户要密码」，一样会挂——追加时只在真有密码时才带。兜底：所有子进程的 stdin 接 `/dev/null`，真要输入时快速失败而不是无限等待。
- **追加用镜像目录绕开参数限制**。7-Zip 没有「放进包内某目录」的开关，条目路径就是命令行给的路径；所以先在临时目录按目标层级搭一棵镜像（文件优先硬链接，跨卷才复制），把 `7zz a` 的工作目录设成镜像根，用相对路径追加。
- **拖出是文件承诺**。`NSItemProvider.registerFileRepresentation` 在**落点索取时**才解压到临时目录，再把同名文件/文件夹交给系统复制；拖拽开始时不预解，避免拖一下 4GB 的包先卡几分钟。
- **密码不落盘**。只在内存里保留到本次压缩/解压结束；代价是 `-p<password>` 会出现在进程参数里（`ps` 可见），换取的是不需要写临时文件。要彻底避开需要改成 stdin 交互，代价是可能挂起，暂不做。
- **路径安全（待接入）**。`PathValidator` 已写好「绝对路径 / `..` / 符号链接逃逸」的判定，但 v1.0 解压流程尚未调用它，当前只靠 7-Zip 自身过滤；接入计划见 PRD §4.4 的 GAP-01。

## 第三方与许可

- 归档引擎：[7-Zip](https://www.7-zip.org/)（`7zz` 26.04），遵循 7-Zip License，全文见 `Threxo/Threxo/Resources/7zip-License.txt`。
- 7-Zip 内含 unRAR 代码，其分发限制已在 `THIRD_PARTY_NOTICES.md` 说明。
- 本仓库为专有代码，版权归作者所有，未经书面许可不得复制、分发或商用，详见 `LICENSE`。

## 文档

| 文档 | 内容 |
| --- | --- |
| `千梭-PRD-v1.2.md` | 15 章 MVP 需求 + 实现差距清单：范围、命令映射、模块划分、RTM、风险登记 |
| `M0/M0-验证报告.md` | M0 技术验证结论（7/7 通过） |
