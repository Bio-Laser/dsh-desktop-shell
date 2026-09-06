# Agent Note: 为 Web GUI 提供一行命令的 Windows 桌面启动器

Status: implemented

[English](2026-08-23-dsh-desktop-shortcut-installer.md) | 中文

## 问题

想要把 dsh Web GUI 当作桌面应用使用的 Windows 用户，要么靠手动敲命令（`node apps/cli/lib/bin.js web --browser-mode edge-app`），要么装一个 PWA——而后者的 scope、缓存和链接路由依赖固定端口，以及 Edge 是系统默认浏览器。没有"双击鲸鱼图标"这种入口。

## 决策

`scripts/install-dsh-desktop.ps1` 在 Windows 上以幂等方式创建桌面入口：

- 从标准安装根目录（`ProgramFiles(x86)`、`ProgramFiles`、`LOCALAPPDATA`）解析 msedge.exe，与 `dsh-web-app` 使用的探测逻辑一致。
- 用 Edge headless 截图（`--headless=new --screenshot`）把 `apps/web/public/favicon.svg`（官方黑鲸鱼图标）渲染成 `scripts/desktop/dsh-favicon.ico`，再手工把 PNG 封装进 ICO 容器——零 npm 图像依赖。
- 在用户桌面上创建 `DeepSeek Harness.lnk` 快捷方式，目标是 `wscript.exe`、参数为提交的 `scripts/desktop/dsh-web.vbs`、`IconLocation` 指向鲸鱼 `.ico`。
- 快捷方式运行 `dsh-web.vbs`，它隐藏地拉起 PowerShell 生命周期脚本 `dsh-web-hide.ps1`（window style 0、`-WindowStyle Hidden`）。

生命周期脚本隐藏启动 `node apps\cli\lib\bin.js web --no-open`，轮询 `http://127.0.0.1:3080` 直到就绪，然后以每次运行唯一的临时 `--user-data-dir` 启动独立 msedge `--app` 进程。打开窗口前，它先在 `HKCU\Software\Classes\AppUserModelId\DeepSeekAI.DeepSeekHarness` 注册任务栏应用身份（显示名 "DeepSeek Harness"、`DefaultIcon` 指向鲸鱼 `.ico`），并以 `--app-user-model-id=DeepSeekAI.DeepSeekHarness` 启动 Edge，使窗口呈现为可固定的独立任务栏应用（黑鲸鱼图标），而非 Edge 窗口。该注册幂等，失败只记录警告，绝不阻断窗口打开。脚本等待该 Edge 进程退出，然后停止占用 3080 端口的服务器。因此关闭 Edge 窗口即停止 dsh。若 3080 已有前一个 dsh 实例在服务，则不启动第二个服务器——脚本复用它，并在窗口关闭时同样停止它。进度与错误追加写入 `%TEMP%\dsh-web.log`。

`-Force` 会重新生成任何已存在的产物；不传时脚本保留现状并说明。非 Windows 主机输出明确信息后退出。批处理文件 `scripts/desktop/dsh-web.bat` 仍提交，作为手动、可见的调试入口。

## 考虑过的替代方案

- **直接提交 `.ico` 而跳过渲染**：checkout 仍会依赖一个来源藏在脚本里的生成二进制；安装时渲染让图标成为源 SVG 的可追溯产物。
- **为转换引入 Node 图像依赖（sharp / png-to-ico）**：为一次 256px 转换引入原生依赖，而目标机器本来就装有 Edge；headless 渲染让仓库保持零新依赖。
- **把 `.lnk` 作为提交文件直接放到桌面**：`.lnk` 是机器相关的二进制（目标路径、图标索引），无法有意义地纳入版本控制；按用户现场生成才是唯一正确的位置。
- **在共享浏览器 profile 中启动 Edge**：`msedge --app=<url>` 会把请求交给正在运行的浏览器并立即退出，因此无法观测窗口关闭。每次运行唯一的临时 `--user-data-dir` 强制独立 Edge 进程，`WaitForExit` 能可靠观测其退出；代价是隔离 profile，不共享浏览器登录态。

## 后果

- `scripts/desktop/dsh-favicon.ico`、`dsh-web.bat`、`dsh-web.vbs` 与 `dsh-web-hide.ps1` 会提交；`.lnk` 只存在于安装用户的桌面。
- `.gitattributes` 增加 `*.bat text eol=crlf`，使提交的批处理文件在仓库内保持 LF、在工作树中呈现 CRLF，cmd.exe 可稳定处理。
- Edge 窗口使用隔离的临时 profile：它是独立的 app 模式视图，不共享浏览器 cookie 或历史，对本地 dsh 表层很干净。
- 关闭 Edge app 窗口会停止 dsh 服务器并释放 3080 端口，对新建服务器与复用服务器统一了停机语义。
- AUMID 注册是隐藏启动器的用户级（`HKCU`）副作用；它让窗口成为真正的任务栏应用（黑鲸鱼图标、可固定），且每次启动重复运行都是安全的。
