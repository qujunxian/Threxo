# 千梭 Threxo

macOS 上的压缩工具。原生 Swift/SwiftUI 写界面，压缩引擎用内置的 7-Zip（`7zz` 26.04），不依赖系统里装了什么。

只解决两件事：在访达右键就能压/解，不弹窗口打断你；想看压缩包里有什么时，不用先解压出来。

## 下载安装

从 [Releases](https://github.com/qujunxian/Threxo/releases) 下载 `Threxo-1.0-macOS-universal.dmg`，拖进「应用程序」。

两个首次使用的坎：

- 没做苹果公证，第一次双击会被系统拦下。在「应用程序」里右键点它 → 选「打开」→ 再点「打开」。
- 右键菜单要手动启用一次：系统设置 → 通用 → 登录项与扩展 → 访达，勾上「千梭」。

系统要求 macOS 14.0+，Apple 芯片和 Intel 通用。

## 用法

**右键**。选中归档时菜单是「用千梭解压」，选中其他东西是「用千梭压缩」，永远只有这一项。

- 解压直接解到压缩包所在文件夹，同名文件自动改名（`a.txt` 变 `a_1.txt`），不覆盖。
- 压缩产物落在源文件旁边，重名就换序号（`a.zip`、`a 2.zip`）。
- 全程不弹窗口，进度在菜单栏，做完发一条系统通知。点通知直接跳到产物位置。
- 如果 App 是为了这次任务才启动的，跑完自己退出。

**打开**。把归档拖到主窗口或 Dock 图标即可。双击也能开，但系统默认还是用「归档实用工具」开 zip——想改成千梭，在文件的「显示简介 → 打开方式」里设一次。

打开后列表里能看到包内结构，可以：

- 选中条目解压到同级文件夹、自选目录，或者直接解到包旁边。
- 把条目拖到访达任意文件夹，松手才开始解压；拖文件夹会连整棵子树一起带出去。
- 把访达里的文件拖进窗口，直接追加到包内对应层级（拖到文件夹行就进那一层，拖到空白处进根目录）。同名时让你选保留两者还是覆盖。

## 格式

能压缩：ZIP、7Z、TAR、GZIP、BZIP2、XZ、WIM。压缩级别四档（`-mx=0/1/5/9`），ZIP 用 AES-256 加密，7Z 用 7zAES。

能解压：以上全部，加上 RAR、DMG、ISO、CAB 等 30 多种，都是 7-Zip 原生支持的。

几个真实存在的限制，不用在界面上猜：

- TAR 和 WIM 不加密。给它们传 `-p` 会被 7-Zip 静默忽略（返回 0，但内容还是明文），所以密码选项对这两种是灰的。
- GZIP/BZIP2/XZ 是单流格式。压目录或多选时先打一层 tar，产物是标准的 `.tar.gz`、`.tar.xz`，解压时自动把那层 tar 拆掉。
- 不创建 RAR，7-Zip 本身不支持（许可也不允许）。
- ZSTD、LZ4、Brotli 那些要 7-Zip ZS 分支才有，官方 `7zz` 返回 rc=2，所以没做。不做假选项。

## 已知问题

- 解压时没有做应用级的路径校验，防 `../` 和绝对路径靠 7-Zip 自己拦。`Core/PathValidator.swift` 写好了但还没接进解压流程。
- 解压直接写到目标目录，没有暂存区，失败或取消会留下半成品。
- 拖拽一次只能拖一行，多选请用「解压所选」。
- 多选多个归档时逐个处理，没有并行。
- 大归档（几千条以上）列表没有虚拟滚动，还没压测过。

## 构建

需要 macOS 14+ 和 Xcode 15 以上。

```bash
open Threxo/Threxo.xcodeproj
# 或
xcodebuild -project Threxo/Threxo.xcodeproj -scheme Threxo -configuration Debug build
```

工程里 `DEVELOPMENT_TEAM = T9DDF2YTVH`，对应作者自己的开发证书。换机器后要在两个 target 的 Signing 里改成自己的 Team，否则签不过。

`7zz` 是二进制直接入库的（`Threxo/Threxo/Resources/7zz`，x86_64 + arm64）。构建时有一条 Run Script 给它补执行权限并重新签名——嵌套的可执行文件不重签，Gatekeeper 会直接拦。

打 DMG：

```bash
xcodebuild -scheme Threxo -configuration Release -derivedDataPath /tmp/threxo-release
mkdir -p /tmp/dmg && cp -R /tmp/threxo-release/Build/Products/Release/Threxo.app /tmp/dmg/
ln -sfn /Applications /tmp/dmg/Applications
hdiutil create -volname "千梭 Threxo" -srcfolder /tmp/dmg -fs HFS+ -format UDZO -ov Threxo.dmg
```

## 目录

```
Threxo/                     Xcode 工程
  Threxo/                   主 App
    ThrexoApp.swift         入口、菜单、URL Scheme、静默任务生命周期
    ContentView.swift       主界面
    CompressOptionsView.swift
    AppModel.swift          状态机：打开/解压/压缩/追加/拖拽
    Core/
      SevenZipRunner.swift  7zz 进程封装、进度与错误解析
      ArchiveLister.swift   l -slt 输出解析成树
      ArchiveEditing.swift  往已有归档追加（镜像目录 + 相对路径）
      ArchiveExport.swift   拖出到访达（落点时才解压）
      Notifier.swift        完成通知
      CompressionOptions.swift
      PathValidator.swift   路径校验（已写，未接入）
    Resources/              7zz、7-Zip 许可、第三方声明
  ThrexoFinder/             Finder Sync 扩展，只负责组菜单
Tools/GenerateIcon.swift    图标绘制脚本
M0/                         立项前的命令行验证
```

图标没有设计文件，`swift Tools/GenerateIcon.swift out.png` 直接画出来。要注意四周留白必须全透明，也不能在底板外画投影，否则 macOS 会当成旧式全出血图标，再给你套一层灰底。

## 几个踩过的坑

写在这里省得下次再查一遍。

**解压必须带 `-p`。** 不给 `-p`，7-Zip 会停下来等终端输入密码，没有终端就卡死。空密码也得传一个空的 `-p`。但 `7zz a` 上的空 `-p` 是另一个意思——它会去问你要密码，一样挂。所以追加时只在真有密码时才带。所有子进程的 stdin 都接到 `/dev/null`，真要输入时快速失败。

**往包里的指定目录追加，得自己搭镜像。** 7-Zip 没有「放到包里某个目录」这种参数，条目路径就是命令行上给的路径。所以在临时目录按目标层级摆一份（文件优先硬链接），把 `7zz a` 的工作目录设成镜像根，用相对路径追加。

**加密 zip 追加要显式写 `-mem=AES256`。** 不写就退化成 ZipCrypto，一个包里混两种加密方式。

**拖出是延迟解压。** 用 `registerFileRepresentation`，等系统真正来要文件时才解到临时目录。拖一个 4GB 的包，不该先解开才看到光标动。

**列目录不能用 `waitUntilExit()` 再读管道。** 进程退出了管道可能还没读完，大归档会解析出 0 条。改成并行读到 EOF。

**通知在老接口上。** macOS 26 上 `UNUserNotificationCenter.requestAuthorization` 对开发签名、未公证的 App 恒定返回 `Notifications are not allowed`，连授权框都不弹；`NSUserNotificationCenter` 反而正常。

**右键不能切后台进程。** 切 `activationPolicy(.accessory)` 之后系统既不弹通知授权，也会把通知静默丢掉。所以静默任务期间 Dock 里是有图标的，那几秒忍一下。

**进度靠解析文本。** `-bsp1` 是退格覆盖式输出，一行里可能有 `0%` `32%` `93%` 好几个百分比，取最后一个。7-Zip 收尾不一定输出 100%，成功时界面自己补。

## 许可

压缩引擎是 [7-Zip](https://www.7-zip.org/)，遵循 7-Zip License，全文在 `Threxo/Threxo/Resources/7zip-License.txt`。其中包含的 unRAR 代码有分发限制，见 `THIRD_PARTY_NOTICES.md`。

本仓库代码为专有软件，未经书面许可不得复制、分发或商用，详见 `LICENSE`。

产品需求见 `千梭-PRD-v1.2.md`，立项前的技术验证记录见 `M0/M0-验证报告.md`。
