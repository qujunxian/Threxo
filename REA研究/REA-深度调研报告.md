# REA（Reverse Engineer Anything）深度调研报告

> 调研日期：2026-10-30 ｜ 数据来源：`github.com/morluto/rea` 官方 README、SECURITY.md、docs/architecture.mermaid、docs/cli.md，及第三方技术调研。  
> 仓库：[morluto/rea](https://github.com/morluto/rea) ｜ 官网：[rea.tools](https://rea.tools/) ｜ 协议：MIT ｜ 语言：TypeScript  
> 当前版本（报告内 `rea --version` 示例）：**6.7.0** ｜ Star：README 头条已突破 **400,000**

---

## 0. 一句话定位

REA **不是反编译器**，而是一&#x4E2A;**「反编译器的 Agent 化编排层」**——一个 MCP Server + CLI。它把 Hopper / Ghidra / IDA / Kuna 等成熟逆向工具封装成统一接口，让 Claude Code / Codex / Cursor 等 AI 编程 Agent 能在**没有源码**的情况下检查软件、解释功能实现，并附带**证据（evidence）**，再帮你在自己的项目里重建该功能。

核心理念：**把「我猜」变成「我看到了证据」**。逆向从「装工具、读汇编的手艺活」变成「会跟 AI 说话就能做」。

---

## 1. 它解决什么痛点

你看到一个喜欢的功能（如某 App 的搜索、某游戏的算法），想在自己项目里复刻，但拿不到源码。传统做法要手工用反汇编器、反编译器、调试器从复杂程序中定位目标。REA 把这些工具接入 AI Agent 后，开发者直接用自然语言描述问题即可：

> "Understand how search works in the Notes app, show me the evidence, and build a similar feature for my project."

随后 Agent 通过 REA：①分析目标程序 → ②追踪功能实现（反编译代码、调用关系、运行行为）→ ③解释程序逻辑 → ④重新实现并验证。REA 不保证自动恢复完整源码，结果完整度取决于目标程序、可用工具与验证过程。

---

## 2. 架构拆解（基于 `docs/architecture.mermaid`）

官方提供了一张分层架构图，明确的不是目录/导入清单，而是**各层的归属与依赖/接线路径**。核心分层如下：

### 2.1 入口层（Entry Points）

- `src/cli.ts` + `src/cli/`：一次性 CLI 适配器（setup、diagnostics、analysis、decompilation）。
- `src/main.ts` + `src/main/`：MCP Server 适配器，**默认 stdio**，可选启用 streamable HTTP；负责 config、session、进程生命周期。
- `scripts/rea.mjs`：可执行分发器，路由 `mcp` / `mcp --http` / 一次性命令。

### 2.2 生产装配层（Production Composition）

- `src/composition/`：受控的强类型 provider 与 session 工厂；一次性绑定 + 独立的按需可选加载；静态 WASM/EVM 描述符（命名契约、工厂、可重试生命周期）。

### 2.3 适配器层（Adapters）

- `src/server/`：MCP 请求翻译（`createServer`、工具注册、`toolResult`）；`http/` 为 streamable HTTP 监听 + `node:http` 桥。
- `bridge/hopper_bridge.py`：**运行在 Hopper 内部**，把操作适配到 Hopper Python API。
- `bridge/ghidra/ReaGhidraBridge.java`：打包的 HeadlessScript（清单、反编译器、引用、CFG）。
- `src/cli/ + src/application/Setup*`：宿主安装适配器（macOS 校验后装 vendor DMG 到 `~/Applications`；Linux 校验后装 vendor 包 + apt/dnf/pacman）。

### 2.4 应用层（Application Layer）

- `src/application/`：CLI/MCP 共享工作流（增强分析、investigations）。
- **`SessionProviderRouter` + `BinarySession`**：每个目标**一个不可变的 deep binding**，离散的辅助路由。
- **`AnalysisProviderRegistry`**：排序后的 deep 候选、确定性选择、**无 fallback（no fallback）**；`ProviderInspectionScope` 控制前置观测生命周期。
- `src/application/investigation/`：`InvestigationRecords` + 窄端口；**`EvidenceLedger`** 与 Unknown 归属。
- `BinarySessionRecords` + `AnalysisSnapshotCache`：目标/剖面快照与 session 文件归属。
- `src/application/javascript/ + src/artifacts/javascript/`：JS 产物重建（目录/ASAR 读取、仅 AST 投影）。

### 2.5 Provider 层（关键）

深分析（原生）provider：

- **Hopper**（`src/hopper/`，Unix-socket 协议，BridgeLauncher/HopperClient）、**Ghidra**（`src/ghidra/`，发现/剖面/函数分析）、**IDA**（上游 MCP 契约适配，活 GUI 绑定或自有 headless 库）、**Kuna**（BYO 深分析候选，仅发现时读元数据）。

内建静态阅读器（进程内、无需外部引擎）：

- Go（`src/go/` 读构建信息）、Rust（`src/rust/` cargo-auditable 依赖）、IL2CPP（`src/il2cpp/` global-metadata.dat）、Flutter（`src/flutter/` Dart build ID）、GPU code objects（`src/gpu/`）、.NET/PE-CLI（`src/dotnet/`）、ELF notes、PE 证书/导入、Apple `.ips`、kernel modules、Erlang BEAM、WASM、EVM（EVMole）、模型产物（GGUF/safetensors）、Godot PCK、PyInstaller 等。

BYO（自备）工具适配器：

- pwntools/pwndbg、WABT（WASM）、Apktool、ADB、JEB（经 MCP）、tshark/sigrok/mitmdump（抓包/信号）、Binwalk/Unblob（固件）、GDB/Rizin/objdump、Frida/Cutter。

### 2.6 Provider 进程基座（Provider Process Foundation）

- `src/process/`：**自有进程组、私有根目录、截止时间、有界文件读取与诊断、清理**。
- `src/windows/` + `native/windows/src/`（Node-API）：NTFS 准入、受保护 DACL、**原子 Job Object 分配**。
- `src/filesystem/`：自有文件/目录句柄、稳定读取、暂存输出。

### 2.7 契约 / 领域 / 配置层

- `src/contracts/`：调用方可见的分析/逆向/托管/浏览器/Electron/应用/session 工具 schema；`errorSchemas.ts` 共享错误契约。
- `src/domain/`：纯无副作用模块（格式声明、provider 选择、Evidence、比较、应用图）。
- `src/config/`：Zod 校验的环境变量解析。

### 2.8 关键架构决策（high-signal）

1. **确定性 provider 选择，无 fallback**——安全与可复现优先，拒绝「偷偷换引擎」。
2. **每目标一个不可变 deep binding**（`BinarySession`）——避免跨目标污染。
3. **Evidence 优先**：每个工具结果 = `result + evidence_id + limitations/unknowns`，可导出/导入/比对（`EvidenceLedger`）。
4. **自有进程组 + 私有根 + 有界读取**——限制意外持久化与资源滥用。
5. **「This is not a sandbox」**——不防同用户恶意进程（见 §7）。

---

## 3. 证据契约与输出模型（CLI & Evidence）

REA 的「诚实性」来自统一的证据契约（`docs/cli.md`）：

- **Evidence 内容** = 产物身份 + 源位置 + 观测 + 推断 + 未决发现；契约明写 *"REA does not fabricate percentages"*，字节与声明 hash 矛盾则 fail-closed 停止。
- **视图投影（Views）**：真实应用的完整 Evidence 可达数百 MB（实测 Obsidian 334 MB），用 `inspect-analysis-view` 投影出 summary（≈10 KB）/ module page / native facet，避免一次性灌入上下文。
- **流式与格式**：`--format jsonl`（逐行记录，含 `metadata` 控制记录）、`--format md/csv/tsv/yaml`；`--token-count` 估算输出体量；输出通过有界格式化分配，避免大文档一次性物化。
- **快照（Snapshots）**：本地缓存，键 = 目标字节 + 操作 + 参数 + provider + 设置；owner-only 权限。命中即复用，免重启 provider 进程。
- **比对**：`rea compare / compare-artifacts`（按 Evidence 身份或显式 record_pairs 比对两个构建/清单），用于版本差异分析。
- **MCP over streamable HTTP**：`rea mcp --http` 默认 loopback；非 loopback 绑定需 `MCP_ALLOWED_HOSTS`，并做 Host/Origin 403 门控，单客户端串行。

---

## 4. 能力矩阵：可分析的目标与 provider

来源 README「What you can analyze」（节选归类）：

| 类别                                    | 返回内容                                    | 依赖 / 指引                                        |
| ------------------------------------- | --------------------------------------- | ---------------------------------------------- |
| 桌面安装                                  | 运行时候选、支持文件、组件标记                         | 内建有界目录/头检查                                     |
| **原生二进制**                             | 伪代码、汇编、字符串、符号、调用/引用                     | **Hopper / Ghidra / IDA / Kuna**（深分析引擎）        |
| Go / Rust / IL2CPP / Flutter / GPU 产物 | 构建信息、依赖图、类型/方法名、Dart build ID、kernel 参数 | 内建进程内静态阅读器，**无需安装对应语言/引擎**                     |
| .NET 程序集                              | 元数据、CIL、原生依赖                            | 纯静态，无引擎                                        |
| JS / Electron                         | 模块、导入、source map、路由、IPC、native addon 关系 | Node + npm；仅 AST，**不运行应用**                     |
| 网站 / 浏览器                              | 页面结构、脚本、网络观测、截图                         | Chrome 系浏览器（CDP/Playwright）                    |
| Android APK                           | Manifest、类、反编译方法、引用                     | Headless JADX + JDK                            |
| Android 真机 / 资源 / JEB                 | 设备/包/进程/日志/转储、解码资源、引擎伪代码                | ADB / Apktool / JEB（MCP）                       |
| 固件                                    | 区域、提取结果、原生分析交接                          | Binwalk / Unblob（Linux）                        |
| WASM / EVM / 捕获包 / 信号 / SQLite        | 校验、选择器、端点/DNS/TLS SNI、寄存器/信号、表数据        | WABT / EVMole / tshark / sigrok / 本地 SQLite 快照 |
| 模型产物 / PyInstaller / Godot PCK        | GGUF/safetensors 元数据、CArchive、包清单       | 内建头部检查，可选全文件 hash                              |

> 注：约 **133+ MCP tools**（README badge 指向「MCP tool catalog」），CLI 命令与 provider 数量随版本增长；Node 要求 **22.23.4+ / 24.22.1+ / 26.12.1+**（23、25 不支持）。

---

## 5. 安装与配置

官方三种方式（`docs/installation.md`）：

```bash
# 方式一：交互式一键配置（支持 Claude Code/Codex/Cursor/Gemini CLI/Grok Build 等 17 个客户端）
npx rea-agents@latest setup

# 方式二：仅装独立 Skill（工作流说明，不等于完成 MCP 配置）
npx skills add morluto/rea --skill reverse-engineer-anything

# 方式三：全局安装 CLI
npm install --global rea-agents && rea --help
```

- 更新：`rea update`（全局装）/ `npx rea-agents@latest setup`（npx 装）。  
  |  |  |  
  | --- | --- |
- 契约调优：`REA_MCP_INPUT_SCHEMA_PROFILE=full`（完整字段指引）、`REA_MCP_OUTPUT_SCHEMA_PROFILE=compact|off`（限制 `tools/list` 体量）。
- ⚠️ **仿冒仓库警告**：真项目仅通过 `morluto/rea`、`rea.tools`、`rea-agents` npm 包分发；**只走 npm，不是 zip 下载**，仓库 owner 必须是 `morluto`。

---

## 6. 安全与信任模型（`SECURITY.md`）

- **会话级随机能力令牌**：Hopper/Ghidra bridge 用每会话随机 capability token 鉴权；POSIX 走当前用户 Unix socket；Windows Ghidra 走**已鉴权的 loopback TCP + 私有 NTFS 运行时（DACL 仅当前用户与 SYSTEM）**；令牌经私有会话描述符传递，不进 argv/环境变量。
- **「This is not a sandbox」**：不防护**已以同一 OS 用户运行的恶意进程**；打开不可信二进制 = 把解析/分析委托给所选本地 provider，使用你的用户权限。
- **Ghidra 会话隔离**：打包 Java HeadlessScript、隔离临时工程、私有 home/cache/runtime；**会话关闭即删临时工程**，不触碰用户自有 Ghidra 工程。
- **Linux Hopper 安装**：仅接受 Hopper HTTPS 端点的发布元数据、限制包 URL 到官方源、校验下载字节与发布 checksum、依赖 `apt-get/dnf/pacman`（直接 root 或 `pkexec`），**绝不调用 `sudo`**。
- 漏洞上报：仓库 Security 标签「Report a vulnerability」或 `morluto@outlook.com`，**禁止在公开 issue 泄露**漏洞/PoC/凭据/私有二进制/Ghidra 工程。

---

## 7. 典型案例（Showcases）

| 案例                      | 做法                                                | 结果                                                                                                   |
| ----------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **DX-Ball**（1996 游戏）    | 追踪声音调用 → 位置到声像的 helper → 补全不完整伪代码 → 转 C           | 通过 **3,205** 个原始 x86 用例，**复现全部 63 个编译字节**；仓库 [N0zoM1z0/dx-ball](https://github.com/N0zoM1z0/dx-ball) |
| **Notion**              | 追 renderer 剪贴板 API → preload → IPC → 主进程，检查富剪贴板格式 | 发现 HTML 中隐藏的 \`\` 结构化 block 存储机制（跨进程边界追踪）                                                            |
| **TH04**（PC-98 DOS 弹幕环） | 检查 16 位指令 → 恢复固定/瞄准角度计算 → 与历史编译器输出比对              | 重建 C++ 与历史编译器输出一致；仓库 [N0zoM1z0/th04](https://github.com/N0zoM1z0/th04)                               |
| **RL 环境**               | 录制 Web 会话 → API 转工具 → 导出 AgentEnv 可用环境            | 用于强化学习训练/评估（[指南](https://rea.tools/guides/rl-environments/)）                                         |

社区复刻（第三方，未经官方背书）：Microsoft Word（界面近像素级）、Claude Slides 编辑器、经典《大富翁4》Flutter→iPhone、TCL 电视浏览器→无广告开源版 Sofa TV Browser、CapCut 风格 ReaCut 等。

---

## 8. 局限、法律与双重用途

- **不恢复原始源码、不整包克隆**：返回伪代码/汇编/模块关系等证据，由 Agent 再写实现；混淆/加壳/冷门架构会让重建极难。
- **本地分析 ≠ 全程私密**：分析在本地、二进制不上传，但工具结果经 Agent **流向模型供应商**——分析专有二进制前需选数据政策合适的模型。
- **静态分析 ≠ 运行时证明**：界面相似、能启动都不等于底层算法一致。
- **商业工具授权**：IDA Pro / Hopper / JEB 需自备 license；REA **明确不提供**任何工具 license/key/激活，**禁止破解、盗key、越权共享**。
- **法律立场**（`DISCLAIMER.md`）：仅用于合法研究、教育、互操作、软件保存，以及你拥有或获授权检查的软件；各地法律不同（如美 DMCA §1201(f)、欧盟 2009/24/EC 第6条有互操作例外）。
- **双重用途背景**：项目爆发期恰逢「AI agent 被用于攻击金融机构」的舆论余波，凸显「agent × 开源工具」已降低攻击门槛——这正是 REA「the old protection was cost」论点最锋利也最具争议之处。

---

## 9. 增长与社区

- 4 月创建（前身 betterBinaryMCP），10 月发布后爆发；README 头条已 **400,000 stars**，长期居 GitHub trending。
- 发版节奏极快（release-please 管理），PR 排队数百，open issues 数百。
- Discord 社区（Q\&A / Show and Tell）；官网提供 guides、showcase、blog。

---

## 10. 相关仓库

- [`JoasASantos/REA-Prompts`](https://github.com/JoasASantos/REA-Prompts)：REA 官方提示词库（26 个技能包）。
- [`morluto/awesome-reverse-engineering`](https://github.com/morluto/awesome-reverse-engineering)：逆向工具/资源清单。
- [`ringozzt/rea-research`](https://github.com/ringozzt/rea-research)：第三方深度技术调研（含交互 report.html / mindmap.html）。
- [`N0zoM1z0/dx-ball`](https://github.com/N0zoM1z0/dx-ball)、[`N0zoM1z0/th04`](https://github.com/N0zoM1z0/th04)：官方 showcase 重建仓库。
- `synortex.com`「Built With REA」：对 8 个社区复刻项目真实性逐条核对（多数属实，个别 REA 贡献被夸大）。

---

## 11. 参考来源（References）

1. 官方仓库 README — <https://github.com/morluto/rea>
2. 架构图 — <https://github.com/morluto/rea/blob/main/docs/architecture.mermaid>
3. 安全策略 — <https://github.com/morluto/rea/blob/main/SECURITY.md>
4. CLI 与证据契约 — <https://github.com/morluto/rea/blob/main/docs/cli.md>
5. 安装与配置 — <https://github.com/morluto/rea/blob/main/docs/installation.md>
6. MCP 契约 — <https://github.com/morluto/rea/blob/main/docs/mcp-contracts.md>
7. 官方网站（guides / showcase）— <https://rea.tools/>
8. 第三方调研 ringozzt/rea-research — <https://github.com/ringozzt/rea-research>
9. 爆款解读（magdigit）— <https://magdigit.com/rea-explained-the-viral-github-repo-that-can-reverse-engineer-anything/>
10. 中文推荐文（微信公众号）— 见搜索结果「喜欢的软件功能, AI 直接复刻——开源项目REA推荐」
11. GitHub 周榜（2026-10-25）— <https://www.cnblogs.com/wflynn/p/23430421>

---

*本报告基于公开资料整理，版本与 star 数随时间快速变化，请以仓库实时状态为准。*
