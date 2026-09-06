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
| `install-dsh-desktop.ps1` | 安装桌面快捷方式（指向 `dsh-web.vbs`） |
| `assets/` | 图标资源（`favicon.ico`、`icon-256.png`，供任务栏/快捷方式复用） |
| `docs/` | 历史实现笔记（edge-app browser mode、desktop shortcut installer） |

## 与上游的关系（迁移说明）

早期版本把"Edge app 模式开窗"实现在 dsh 仓库内（`web-app` bundle 的 `browserMode` 配置 + `--browser-mode` flag）。该方案已废弃：
- 开窗职责上移到本壳层（`--no-open` + 自开窗），上游 `web-app` 保持纯净
- 上游更新（`git fetch origin && git rebase origin/master`）不再与任何定制文件冲突

## 构建与运行

- WebView2 壳：`dotnet publish webview2-shell/WebView2Shell.csproj -c Release -r win-x64`（输出到 `bin/Release/net8.0-windows/win-x64/publish/`）
- 生命周期：双击桌面快捷方式（→ vbs → ps1）；或直接跑 `powershell -ExecutionPolicy Bypass -File scripts\dsh-web-hide.ps1`
- 调试：`scripts\dsh-web.bat`

### 窗口标题（浏览器标签页标题）

WebView2/Edge 窗口标题取自页面 `<title>`，由 dsh 构建时注入（Vite `transformIndexHtml` 读 `process.env.DSH_CLIENT_TITLE`）。要让窗口显示 "DeepSeek Harness" 而非默认的 "DSH Local Build"，**构建 dsh 前端时**设置环境变量：

```powershell
$env:DSH_CLIENT_TITLE = 'DeepSeek Harness'
pnpm run build        # 或你的构建命令（dev 模式同理：启动 dev:web 前设置）
```

运行期设置无效——标题在构建时固化进 `dist/index.html`。
