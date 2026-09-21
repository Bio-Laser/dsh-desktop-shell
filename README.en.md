<div align="center">

# DeepSeek Harness · Desktop Shell

**Give the DeepSeek Harness Web GUI its own window, icon, and taskbar identity.**

![platform](https://img.shields.io/badge/platform-Windows%2010%201809%2B-0078D6)
![.NET](https://img.shields.io/badge/.NET-8-512BD4)
![WebView2](https://img.shields.io/badge/WebView2-Evergreen-0F7DC2)
![license](https://img.shields.io/badge/license-MIT-3DA639)

[![中文](https://img.shields.io/badge/%E4%B8%AD%E6%96%87-informational)](README.md)
![English](https://img.shields.io/badge/English-lightgrey)

</div>

---

## What this is

One chain that turns the in-browser Harness into a real desktop application:

```
Desktop shortcut
   └─ wscript + VBS      starts with no console window
        └─ PowerShell    lifecycle management
             └─ WebView2 native window ──▶  dsh web --no-open
```

Double-click the icon: the window appears and the server is started when needed. Close the window: the server **this launch** started is stopped.

## Highlights

| Capability | Detail |
|---|---|
| **Native window and taskbar identity** | The GUI runs in WebView2 with its own AppUserModelID (`DeepSeekAI.DeepSeekHarness`), so it is pinnable and carries its own title and icon |
| **Zero intrusion** | No dsh source is modified; window, icon, and lifecycle all live here, and dsh only provides `web --no-open` |
| **ServerLease lifecycle** | Stops only the server it started; a dsh already serving port 3080 keeps running untouched |
| **No token wrangling** | Navigates to the authenticated URL parsed from the server's `dsh web: <url>` banner, so the page never stalls on 401 |
| **Native notifications** | Grants the loopback origin's Notifications permission and re-renders each notification as a Windows toast; clicking restores and activates the window |
| **No idle waiting** | Readiness probes use a 300 ms TCP connect instead of a 2 s HTTP timeout, and WebView2 initialization runs **in parallel** with server startup |
| **One-command install** | `install-dsh-desktop.ps1` creates the desktop shortcut idempotently |
| **Single icon source** | `assets/icon-256.png` → `assets/favicon.ico`, shared by the shortcut and the executable |
| **Self-healing links** | `sync-profile-links.ps1` fills in the profile's `@deepseek-ai` junctions; the whole scan is skipped while the dsh HEAD is unchanged |

## Quick start

### Prerequisites

| Dependency | Notes |
|---|---|
| Windows 10 1809+ | Fixed by `SupportedOSPlatformVersion` = 10.0.17763.0 |
| .NET 8 Runtime | The shell is framework-dependent (`SelfContained=false`) |
| WebView2 Evergreen Runtime | Required by the native window; a missing runtime shows an error at launch |
| Node.js | Needed to start `apps/cli/lib/bin.js web --no-open` |
| Microsoft Edge | Only for the fallback path used before the WebView2 host is published |
| A dsh checkout | Must resolve to `apps/cli/lib/bin.js`; see "Path resolution" |

### Install

```powershell
git clone <this repo> D:\dsh-desktop-shell
cd D:\dsh-desktop-shell

# 1) Publish the WebView2 native window (preferred path)
dotnet publish webview2-shell\WebView2Shell.csproj -c Release -r win-x64

# 2) Install the desktop shortcut (kept if present; -Force recreates it)
powershell -ExecutionPolicy Bypass -File install-dsh-desktop.ps1
```

Then double-click **DeepSeek Harness** on the desktop.

### Manual debugging

```powershell
# Console attached, server stays in this window, no automatic window
scripts\dsh-web.bat

# Full lifecycle (hidden)
powershell -ExecutionPolicy Bypass -File scripts\dsh-web-hide.ps1
```

## Layout

| Path | Purpose |
|---|---|
| `webview2-shell/` | C# WebView2 form (preferred): own taskbar identity; starts the server when the URL is not yet ready and stops that child when the window closes |
| `scripts/dsh-web.vbs` | Shortcut entry point: runs the lifecycle script with no visible window |
| `scripts/dsh-web-hide.ps1` | Hidden lifecycle: prefers the published WebView2 host and falls back to an Edge app-mode window |
| `scripts/dsh-web.bat` | Manual debug entry: shows the console and serves with `--no-open` (no automatic window) |
| `scripts/dsh-shell-common.ps1` | Shared module: resolves the shell root and the dsh checkout, readiness check, logging |
| `scripts/sync-profile-links.ps1` | Keeps the profile's `@deepseek-ai` junctions in sync: adds missing links, prunes links whose target is gone |
| `scripts/build-desktop-icon.ps1` | Generates `assets/favicon.ico` from `assets/icon-256.png` (no image library) |
| `install-dsh-desktop.ps1` | Installs or recreates the desktop shortcut (idempotent) |
| `dsh-shell.config.example.json` | Machine-local config template: copy to `dsh-shell.config.json` and set `dshRepoRoot` |
| `assets/` | Single icon source: `icon-256.png` is the source, `favicon.ico` is generated from it |
| `docs/` | Design notes and implementation trade-offs |

## How it works

### Startup and shutdown (ServerLease)

The shell follows one ownership rule: **whoever starts it stops it.**

- When the window opens, the target URL is probed first. If a dsh already answers on port 3080, the shell attaches and never starts a second server; closing the window leaves it running.
- If nothing answers, the shell starts `apps/cli/lib/bin.js web --no-open` and stops **that** child when the window closes (or when WebView2 initialization fails).

Multiple windows, or a long-lived server started with `dsh-web.bat`, therefore never fight over the port.

### Readiness

Ready means "something is listening at that address": a successful connect is enough, and the bearer fence answering 401 counts too.

Probing uses a **300 ms TCP connect budget**. That is deliberate: some security/VPN filter drivers hold a connect to an unbound port until the OS SYN-retransmit window (~2 s), so a full-budget probe would add two seconds to every cold start.

### Token and attaching to a running server

The dsh server is protected by a bearer token; requests without it get 401.

- **Server started by the shell**: the shell parses the `dsh web: <url>` banner from stdout and navigates to the tokenized URL, so the GUI loads.
- **Attaching to a running server**: its stdout is not ours to read, so the shell falls back to the configured `http://127.0.0.1:3080` and the page stalls on 401. Pass the tokenized URL the server printed as the first argument:

```powershell
& 'webview2-shell\bin\Release\net8.0-windows10.0.17763.0\win-x64\publish\DeepSeek Harness.exe' '<tokenized URL>'
```

### Window title

The WebView2/Edge window title comes from the page `<title>`. To show "DeepSeek Harness", set the environment variable **when building the dsh frontend**:

```powershell
$env:DSH_CLIENT_TITLE = 'DeepSeek Harness'
pnpm run build
```

Setting it at runtime has no effect — the title is baked into `dist/index.html` at build time.

## Path resolution (dsh checkout)

The C# host and the PowerShell scripts resolve the dsh checkout in the same order, stopping at the first hit:

1. The `DSH_REPO_ROOT` environment variable
2. `dshRepoRoot` in `dsh-shell.config.json` (copy the template and fill it in)
3. Auto-detection: sibling directories of this checkout that contain `apps/cli/lib/bin.js`
4. Walking upwards from the executable path and the current working directory

When every candidate fails, the C# side throws `FileNotFoundException` with a hint, and the scripts log to `%TEMP%\dsh-web.log` and exit.

## Build and publish

```powershell
dotnet restore webview2-shell/WebView2Shell.csproj
dotnet publish webview2-shell/WebView2Shell.csproj -c Release -r win-x64
```

Output: `webview2-shell\bin\Release\net8.0-windows*\win-x64\publish\DeepSeek Harness.exe`.

> Close any running window before publishing — `publish` fails while the executable is in use.

## Logs and troubleshooting

Lifecycle log: `%TEMP%\dsh-web.log`.

| Symptom | Fix |
|---|---|
| Page stalls on 401 / stays blank | It attached to a running server; pass the tokenized URL as the first argument |
| `server did not become ready within 30s` | Port occupied or Node missing from PATH; stop stray node processes and check `node -v` |
| `Could not locate apps/cli/lib/bin.js` | Set `DSH_REPO_ROOT`, or write `dsh-shell.config.json` |
| It only opens an Edge window | The WebView2 host is not published; run `dotnet publish` above |
| Wrong icon | Regenerate: `scripts\build-desktop-icon.ps1 -Force`, then `install-dsh-desktop.ps1 -Force` |

## License

MIT
