# dsh-desktop-shell

Windows 桌面壳层：把 DeepSeek Harness Web GUI 跑成独立桌面应用（独立任务栏身份、自定义图标）。

独立于 dsh 上游仓库的 Git 仓库。**dsh 上游源码零改动**——所有"窗口/图标/生命周期"职责都在本仓库。

## 架构

**职责分工**：dsh 只负责 `web --no-open` 提供服务；**壳层负责开窗与收尾**（ServerLease 语义：只停止本次启动的服务器，端口 3080 上已存在的 dsh 继续运行）。

| 组件 | 作用 |
|---|---|
| `webview2-shell/` | C# WebView2 窗体（首选）：任务栏自有的 DeepSeek Harness 窗口。URL 未就绪时自行启动 `apps/cli/lib/bin.js web --no-open`，窗口关闭时停止该子进程 |
| `scripts/dsh-web-hide.ps1` | 隐藏生命周期（WebView2 未发布时的回退路径）：`--no-open` 起服务 → 轮询 `http://127.0.0.1:3080` → 以临时 profile 启动独立 msedge `--app` 窗口（自定义 AUMID + 黑鲸图标）→ 窗口关闭则停止本次启动的服务器 |
| `scripts/dsh-web.vbs` | 桌面快捷方式入口：无窗口地调用 `dsh-web-hide.ps1` |
| `scripts/dsh-web.bat` | 手动调试入口：显示控制台、`--no-open` 起服务（不自动开窗） |
| `install-dsh-desktop.ps1` | 安装桌面快捷方式（指向 `dsh-web.vbs`），幂等；`-Force` 重建 |
| `scripts/dsh-shell-common.ps1` | 共享模块：统一解析"本仓库根 / dsh 检出根"、定位 WebView2 壳、就绪判定与日志 |
| `scripts/build-desktop-icon.ps1` | 由 `assets/icon-256.png` 生成 `assets/favicon.ico`（零图像依赖） |
| `scripts/sync-profile-links.ps1` | 同步 profile 的 `@deepseek-ai` 依赖链接：上游新增包后补齐 Junction，`-RemoveDangling` 清理目标已消失的链接。默认只报告，`-Apply` 才改动；dsh 的 HEAD 未变则整段跳过 |
| `dsh-shell.config.example.json` | 机器本地配置模板：复制为 `dsh-shell.config.json` 并填 `dshRepoRoot`（该文件已被 `.gitignore` 忽略） |
| `assets/` | 图标唯一来源：`icon-256.png` 为源，`favicon.ico` 由其生成，供快捷方式与可执行文件共用 |
| `docs/` | 历史实现笔记（edge-app browser mode、desktop shortcut installer） |

## 与上游的关系（迁移说明）

早期版本把"Edge app 模式开窗"实现在 dsh 仓库内（`web-app` bundle 的 `browserMode` 配置 + `--browser-mode` flag）。该方案已废弃：
- 开窗职责上移到本壳层（`--no-open` + 自开窗），上游 `web-app` 保持纯净
- 上游更新（`git fetch origin && git rebase origin/master`）不再与任何定制文件冲突

## 前置条件

| 依赖 | 说明 |
|---|---|
| Windows 10 1809+ | 由 `SupportedOSPlatformVersion` = 10.0.17763.0 决定 |
| .NET 8 Runtime | 壳为 framework-dependent（`SelfContained=false`） |
| WebView2 Evergreen Runtime | WebView2 窗体必需；缺失时启动会弹出错误提示 |
| Node.js | 壳拉起 `apps/cli/lib/bin.js web --no-open` 需要 |
| Microsoft Edge | 仅 WebView2 壳尚未发布时的回退路径需要 |
| dsh 检出 | 需能定位到 `apps/cli/lib/bin.js`，见下方"路径解析" |

### 路径解析（dsh 检出位置）

壳（C#）与脚本（PowerShell）按同一顺序定位 dsh 检出根目录，命中即止：

1. 环境变量 `DSH_REPO_ROOT`
2. `dsh-shell.config.json` 中的 `dshRepoRoot`（复制 `dsh-shell.config.example.json` 后填写）
3. 自动探测：本仓库同级目录中含有 `apps/cli/lib/bin.js` 的目录
4. 从可执行文件 / 当前工作目录逐级向上查找

全部失败时，C# 侧抛 `FileNotFoundException` 并提示；脚本侧写日志到 `%TEMP%\dsh-web.log` 后退出。

## 构建与运行

- WebView2 壳：`dotnet publish webview2-shell/WebView2Shell.csproj -c Release -r win-x64`（输出到 `bin/Release/net8.0-windows10.0.17763.0/win-x64/publish/`）
- 生命周期：双击桌面快捷方式（→ vbs → ps1）；或直接跑 `powershell -ExecutionPolicy Bypass -File scripts\dsh-web-hide.ps1`
- 调试：`scripts\dsh-web.bat`

### 复用已有服务器时的 token 说明

dsh 的服务受 bearer token 保护，未带 token 的请求返回 401。壳层就绪判定把 401 也视为"已就绪"，但导航行为不同：

- **壳自己启动的服务**：从 stdout 的 `dsh web: <url>` banner 解析出带 token 的地址并导航，可正常加载。
- **附加到已运行的 dsh**：读不到它的 stdout，只能退回配置的 `http://127.0.0.1:3080`，页面会停在 401。

第二种情况请把 dsh 启动时打印的带 token 的地址作为第一个参数传入：

```powershell
& 'webview2-shell\bin\Release\net8.0-windows10.0.17763.0\win-x64\publish\DeepSeek Harness.exe' '<dsh web 启动时打印的 URL>'
```

### 窗口标题（浏览器标签页标题）

WebView2/Edge 窗口标题取自页面 `<title>`，由 dsh 构建时注入（Vite `transformIndexHtml` 读 `process.env.DSH_CLIENT_TITLE`）。要让窗口显示 "DeepSeek Harness" 而非默认的 "DSH Local Build"，**构建 dsh 前端时**设置环境变量：

```powershell
$env:DSH_CLIENT_TITLE = 'DeepSeek Harness'
pnpm run build        # 或你的构建命令（dev 模式同理：启动 dev:web 前设置）
```

运行期设置无效——标题在构建时固化进 `dist/index.html`。
