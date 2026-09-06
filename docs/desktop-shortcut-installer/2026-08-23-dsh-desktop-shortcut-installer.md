# Agent Note: One-command Windows desktop launcher for the Web GUI

Status: implemented

English | [中文](2026-08-23-dsh-desktop-shortcut-installer.zh.md)

## Problem

A Windows user who wants the dsh Web GUI as a desktop app is stuck with either a manual terminal command (`node apps/cli/lib/bin.js web --browser-mode edge-app`) or an installed PWA whose scope, caching, and link-routing depend on a fixed port and Edge being the system default browser. There is no "double-click the whale" entry point.

## Decision

`scripts/install-dsh-desktop.ps1` creates the desktop entry point idempotently on Windows:

- Resolves msedge.exe from the standard install roots (`ProgramFiles(x86)`, `ProgramFiles`, `LOCALAPPDATA`), the same probe `dsh-web-app` uses.
- Renders `apps/web/public/favicon.svg` (the official black-whale icon) into `scripts/desktop/dsh-favicon.ico` via an Edge headless screenshot (`--headless=new --screenshot`), then wraps the PNG in an ICO container by hand — zero npm image dependency.
- Creates a `DeepSeek Harness.lnk` on the user's Desktop whose target is `wscript.exe` with the committed `scripts/desktop/dsh-web.vbs` as its argument, and the whale `.ico` as `IconLocation`.
- The shortcut runs `dsh-web.vbs`, which hides the PowerShell lifecycle script `dsh-web-hide.ps1` (window style 0, `-WindowStyle Hidden`).

The lifecycle script starts `node apps\cli\lib\bin.js web --no-open` hidden, polls `http://127.0.0.1:3080` until it accepts, then launches an independent msedge `--app` process with a per-run temporary `--user-data-dir`. Before opening the window it registers a taskbar application identity under `HKCU\Software\Classes\AppUserModelId\DeepSeekAI.DeepSeekHarness` (display name "DeepSeek Harness" and `DefaultIcon` pointing at the whale `.ico`) and launches Edge with `--app-user-model-id=DeepSeekAI.DeepSeekHarness`, so the window presents as its own pinnable taskbar app with the black-whale icon instead of an Edge window. The registration is idempotent and a failure only logs a warning — it never blocks the window. The script waits for that Edge process to exit, then stops the server that owns port 3080. Closing the Edge window therefore stops dsh. If port 3080 already serves a previous dsh, no second server is started — the script reuses it and still stops it when the window closes. Progress and errors append to `%TEMP%\dsh-web.log`.

`-Force` regenerates any already-existing artifact; without it the script keeps what exists and reports so. Non-Windows hosts exit with a clear message. The batch file `scripts/desktop/dsh-web.bat` remains committed as a manual, visible debug entry point.

## Alternatives considered

- **Ships the `.ico` committed and skips rendering**: the checkout would still depend on a generated binary whose provenance is a hidden script; rendering at install time keeps the icon a traceable product of the source SVG.
- **Adds a Node image dependency (sharp / png-to-ico) for the conversion**: a native dependency for a one-time 256px conversion, when the target machine already runs Edge; headless rendering keeps the repo dependency-free.
- **Puts the `.lnk` directly on the Desktop from a committed file**: `.lnk` is a machine-specific binary (target paths, icon indexes) that cannot be meaningfully versioned; generating it per-user is the only correct place.
- **Starts Edge in the shared browser profile**: `msedge --app=<url>` hands the request to a running browser and exits immediately, so the window cannot be observed for close. A per-run temporary `--user-data-dir` forces an independent Edge process whose exit `WaitForExit` observes reliably; the trade-off is an isolated profile with no shared browser login state.

## Consequences

- `scripts/desktop/dsh-favicon.ico`, `dsh-web.bat`, `dsh-web.vbs`, and `dsh-web-hide.ps1` are committed; the `.lnk` lives only on the installing user's Desktop.
- `.gitattributes` gains `*.bat text eol=crlf` so the committed batch file stays LF in-repo and presents CRLF in the working tree, which cmd.exe handles reliably.
- The Edge window uses an isolated temporary profile: it is a standalone app-mode view with no shared browser cookies or history, which is clean for a local dsh surface.
- Closing the Edge app window stops the dsh server and frees port 3080, unifying shutdown semantics for both fresh and reused servers.
- The AUMID registration is a user-level (`HKCU`) side effect of the hidden launcher; it makes the window a real taskbar application (whale icon, pinnable) and is safe to re-run at every launch.
