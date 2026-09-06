# Agent Note: 为 Web runtime 增加 Edge app 模式桌面交接

Status: implemented

[English](2026-08-23-web-app-edge-app-browser-mode.md) | 中文

## 问题

`dsh web` 始终通过 `open` 包把规范本地 URL 交给操作系统默认浏览器。用户希望界面常驻独立桌面窗口（从 `http://127.0.0.1:3080` 安装的 PWA，或希望如此）时，每次启动都会得到一个新的浏览器标签页，而且交接目标无法在调用时选择。

## 决策

Web runtime 新增经过校验的 `browserMode` 配置字段，取值 `'default' | 'edge-app'`，默认 `'default'`。`web-startup` 接受对应的仅本次调用生效的 `--browser-mode <mode>` flag，经 `webStartup` 发布，并由 `cordis.patch.yml` 的 `web-runtime` 行接通（`ctx.webStartup.browserMode ?? 'default'`）。当 `openBrowser` 激活且 `browserMode` 为 `edge-app` 时，插件从 Windows 标准安装根目录（`ProgramFiles(x86)`、`ProgramFiles`、`LOCALAPPDATA`）解析 msedge.exe，并将 URL 交给 `open(url, { app: { name: <edgePath>, arguments: ['--app=' + url] } })`，从而打开无地址栏的独立 Edge app 模式窗口。在非 Windows 平台或找不到候选路径时，输出 stderr 提示并回退到默认浏览器，因此该模式永远不会让启动失败。`--no-open`、SSH 交接抑制、脱敏子进程环境与 Windows 等待 launcher 的语义均保持不变，`default` 模式路径与之前逐字节一致。`internals.openBrowser` 现在接受 `(url, mode, edgePath)`，并注入 `internals.resolveEdgeExecutable` 以支持确定性测试。

## 考虑过的替代方案

- **把交接留给默认浏览器并依赖 Edge 的自动链接处理**：零代码，但它依赖 Edge 是系统默认浏览器、端口固定且始终落在已安装 PWA 的 scope 内，以及每台机器 `edge://apps` 的链接处理设置；这些都不受本次调用控制。
- **通过 `explorer.exe shell:AppsFolder\<AUMID>` 启动已安装 PWA 的 AppUserModelID**：它会打开 PWA 固定的 `start_url`，无法携带本次调用的动态端口，因此无法指向正在运行的 `dsh web` 服务器。
- **让 `browserMode` 只作为部署配置、不加 CLI flag**：flag 是终端启动的用户无需编辑 profile 即可尝试该模式的唯一途径；它遵循 `--no-open` 的先例，属于仅本次调用生效的覆盖。

## 后果

- 在装有 Edge 的 Windows 上，`dsh web --browser-mode edge-app` 会把界面开进独立应用窗口而非浏览器标签页；由于窗口就是 Edge 的 app 模式外壳，PWA 问题不再存在。
- 打开的窗口是 Edge 的 app 模式外壳，而非已安装的 PWA 实例：Service Worker scope 与安装驱动功能不适用。
- 非 Windows 或解析不到 Edge 时，`edge-app` 静默降级到默认浏览器，仅输出一条 stderr 提示；没有硬失败，也没有新的退出路径。
- `--browser-mode` 加入已校验的 flag 家族；未知取值会在消费者激活前被拒绝。
- `resolveEdgeExecutable` 辅助函数与模式传递均在不真正启动 Edge 的情况下完成单元测试，CLI browser-open snapshot fixture 仍只接收 `(url)` 并忽略多余 argv。
