<div align="center">

# DeepSeek Harness · Desktop Shell

**让 DeepSeek Harness 的 Web GUI 拥有自己的窗口、图标与任务栏身份。**

![platform](https://img.shields.io/badge/platform-Windows%2010%201809%2B-0078D6)
![.NET](https://img.shields.io/badge/.NET-8-512BD4)
![WebView2](https://img.shields.io/badge/WebView2-Evergreen-0F7DC2)
![license](https://img.shields.io/badge/license-MIT-3DA639)

![中文](https://img.shields.io/badge/%E4%B8%AD%E6%96%87-lightgrey)
[![English](https://img.shields.io/badge/English-informational)](README.en.md)

</div>

---

## 这是什么

一条链路，把浏览器里的 Harness 变成一个真正的桌面应用：

```
桌面快捷方式
   └─ wscript + VBS      无黑框启动
        └─ PowerShell    生命周期管理
             └─ WebView2 原生窗口 ──▶  dsh web --no-open
```

双击图标：窗口出现，服务按需自动拉起；关闭窗口：**本次**拉起的服务随之退出。

## 亮点

| 能力 | 说明 |
|---|---|
| **原生窗口与任务栏身份** | WebView2 承载 GUI，注册独立 AUMID（`DeepSeekAI.DeepSeekHarness`），可固定到任务栏，窗口标题与图标都是自己的 |
| **零侵入** | 不修改 dsh 任何源码；窗口、图标、生命周期全部由本仓库负责，dsh 只提供 `web --no-open` |
| **ServerLease 生命周期** | 只停止「本次启动」的服务器；端口 3080 上已在运行的 dsh 继续运行、不受影响 |
| **免 token 折腾** | 从服务器 stdout 的 `dsh web: <url>` banner 解析出带 token 的地址并直接导航，不会停在 401 |
| **原生通知** | 允许回环源的 Notification 权限，并把每条通知转成 Windows 原生 Toast；点击后恢复并激活窗口 |
| **启动不再干等** | 就绪探测改用 300ms TCP 连接（而不是 2s HTTP 超时）；WebView2 初始化与服务器启动**并行** |
| **一键安装** | `install-dsh-desktop.ps1` 幂等创建桌面快捷方式，重复执行安全 |
| **图标单源** | `assets/icon-256.png` → `assets/favicon.ico`，快捷方式与可执行文件共用同一图标 |
| **链路自愈** | `sync-profile-links.ps1` 自动补齐 profile 的 `@deepseek-ai` 链接；dsh 的 HEAD 未变则整段跳过 |

## 快速开始

### 前置条件

| 依赖 | 说明 |
|---|---|
| Windows 10 1809+ | 由 `SupportedOSPlatformVersion` = 10.0.17763.0 决定 |
| .NET 8 Runtime | 壳为 framework-dependent（`SelfContained=false`） |
| WebView2 Evergreen Runtime | 原生窗口必需；缺失时启动会弹出错误提示 |
| Node.js | 拉起 `apps/cli/lib/bin.js web --no-open` 需要 |
| Microsoft Edge | 仅在 WebView2 壳尚未发布时的回退路径需要 |
| dsh 检出 | 需能定位到 `apps/cli/lib/bin.js`，见「路径解析」 |

### 安装

```powershell
git clone <this repo> D:\dsh-desktop-shell
cd D:\dsh-desktop-shell

# 1) 发布 WebView2 原生窗口（首选路径）
dotnet publish webview2-shell\WebView2Shell.csproj -c Release -r win-x64

# 2) 安装桌面快捷方式（存在即保留，-Force 重建）
powershell -ExecutionPolicy Bypass -File install-dsh-desktop.ps1
```

然后双击桌面上的 **DeepSeek Harness** 图标。

### 手动调试

```powershell
# 带控制台，本窗口内保留服务，不自动开窗
scripts\dsh-web.bat

# 走完整生命周期（隐藏窗口）
powershell -ExecutionPolicy Bypass -File scripts\dsh-web-hide.ps1
```

## 目录结构

| 路径 | 作用 |
|---|---|
| `webview2-shell/` | C# WebView2 窗体（首选）：独立任务栏身份；URL 未就绪时自行拉起服务器，窗口关闭时停止该子进程 |
| `scripts/dsh-web.vbs` | 桌面快捷方式入口：以无窗口方式调用生命周期脚本 |
| `scripts/dsh-web-hide.ps1` | 隐藏生命周期：优先启动已发布的 WebView2 壳，未发布时回退为 Edge 应用模式窗口 |
| `scripts/dsh-web.bat` | 手动调试入口：显示控制台、`--no-open` 起服务（不自动开窗） |
| `scripts/dsh-shell-common.ps1` | 共享模块：解析「本仓库根 / dsh 检出根」、就绪判定与日志 |
| `scripts/sync-profile-links.ps1` | 同步 profile 的 `@deepseek-ai` 依赖链接：补齐缺失 Junction，清理目标已消失的链接 |
| `scripts/build-desktop-icon.ps1` | 由 `assets/icon-256.png` 生成 `assets/favicon.ico`（零图像依赖） |
| `install-dsh-desktop.ps1` | 安装/重建桌面快捷方式（幂等） |
| `dsh-shell.config.example.json` | 机器本地配置模板：复制为 `dsh-shell.config.json` 并填 `dshRepoRoot` |
| `assets/` | 图标唯一来源：`icon-256.png` 为源，`favicon.ico` 由其生成 |
| `docs/` | 设计笔记与实现取舍记录 |

## 工作方式

### 启动与收尾（ServerLease）

壳层遵循一套明确的归属规则：**谁启动，谁负责停止。**

- 窗口打开时先探测目标 URL。端口 3080 上已有 dsh 在响应 → 直接附加，**不**再启动第二个服务；窗口关闭时不动它。
- 没有任何服务响应 → 拉起 `apps/cli/lib/bin.js web --no-open`，并在窗口关闭（或 WebView2 初始化失败）时停止**这个**子进程。

因此多开窗口、或用 `dsh-web.bat` 常驻一个服务时，都不会互相踩踏。

### 就绪判定

判定标准是「该地址上有监听者」：连接成功即视为就绪，带 token 围栏返回 401 也算数。

探测使用 **300ms 预算的 TCP 连接**。这是刻意的：部分安全/VPN 过滤驱动会让「连接未监听端口」一直挂到系统 SYN 重传窗口（约 2s）才失败，用完整预算探测会给每次冷启动平白加上两秒。

### token 与附加到已有服务

dsh 的服务受 bearer token 保护，未带 token 的请求返回 401。

- **壳自己启动的服务**：解析其 stdout 的 `dsh web: <url>` banner，用带 token 的地址导航，正常加载。
- **附加到已运行的服务**：读不到它的 stdout，只能退回配置的 `http://127.0.0.1:3080`，页面会停在 401。此时把 dsh 启动时打印的带 token 地址作为第一个参数传入：

```powershell
& 'webview2-shell\bin\Release\net8.0-windows10.0.17763.0\win-x64\publish\DeepSeek Harness.exe' '<带 token 的 URL>'
```

### 窗口标题

WebView2/Edge 窗口标题取自页面 `<title>`。要让窗口显示 "DeepSeek Harness"，需在**构建 dsh 前端时**设置：

```powershell
$env:DSH_CLIENT_TITLE = 'DeepSeek Harness'
pnpm run build
```

运行期设置无效——标题在构建时固化进 `dist/index.html`。

## 路径解析（dsh 检出位置）

壳（C#）与脚本（PowerShell）按同一顺序定位 dsh 检出根目录，命中即止：

1. 环境变量 `DSH_REPO_ROOT`
2. `dsh-shell.config.json` 中的 `dshRepoRoot`（复制模板后填写）
3. 自动探测：本仓库同级目录中含有 `apps/cli/lib/bin.js` 的目录
4. 从可执行文件 / 当前工作目录逐级向上查找

全部失败时：C# 侧抛 `FileNotFoundException` 并提示；脚本侧写日志到 `%TEMP%\dsh-web.log` 后退出。

## 构建与发布

```powershell
dotnet restore webview2-shell/WebView2Shell.csproj
dotnet publish webview2-shell/WebView2Shell.csproj -c Release -r win-x64
```

输出：`webview2-shell\bin\Release\net8.0-windows*\win-x64\publish\DeepSeek Harness.exe`。

> 发布前请先关闭正在运行的窗口——可执行文件被占用时 `publish` 会失败。

## 日志与故障排查

生命周期日志：`%TEMP%\dsh-web.log`。

| 现象 | 处理 |
|---|---|
| 页面停在 401 / 空白 | 附加到了已有服务；改用带 token 的 URL 作为第一个参数 |
| `server did not become ready within 30s` | 端口被占用或 Node 不在 PATH；先关掉残留的 node，确认 `node -v` |
| `Could not locate apps/cli/lib/bin.js` | 设置 `DSH_REPO_ROOT`，或写 `dsh-shell.config.json` |
| 只是回退到 Edge 窗口 | WebView2 壳未发布；执行上面的 `dotnet publish` |
| 图标显示不对 | 重新生成：`scripts\build-desktop-icon.ps1 -Force`，再 `install-dsh-desktop.ps1 -Force` |

## License

MIT
