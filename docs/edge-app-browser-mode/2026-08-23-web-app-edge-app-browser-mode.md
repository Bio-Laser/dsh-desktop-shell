# Agent Note: Add an Edge app-mode desktop handoff to the Web runtime

Status: implemented

English | [中文](2026-08-23-web-app-edge-app-browser-mode.zh.md)

## Problem

`dsh web` always hands the canonical local URL to the operating system's default browser through the `open` package. A user who keeps the UI open in a standalone desktop window (a PWA installed from `http://127.0.0.1:3080`, or a wish for one) gets a fresh browser tab on every launch instead, and the handoff target cannot be chosen at invocation time.

## Decision

The web runtime gains a validated `browserMode` config field, `'default' | 'edge-app'`, defaulting to `'default'`. `web-startup` accepts a matching invocation-only `--browser-mode <mode>` flag, published on `webStartup` and wired through `cordis.patch.yml`'s `web-runtime` row (`ctx.webStartup.browserMode ?? 'default'`). When `openBrowser` is active and `browserMode` is `edge-app`, the plugin resolves msedge.exe from the standard Windows install roots (`ProgramFiles(x86)`, `ProgramFiles`, `LOCALAPPDATA`) and hands the URL to `open(url, { app: { name: <edgePath>, arguments: ['--app=' + url] } })`, opening a standalone, address-bar-less Edge app-mode window. On non-Windows platforms or when no candidate exists, it logs a stderr note and falls back to the default browser, so the mode never fails the launch. `--no-open`, the SSH handoff suppression, the scrubbed child environment, and the Windows wait-for-launcher semantics are unchanged, and the `default` mode path is byte-for-byte the previous one. `internals.openBrowser` now takes `(url, mode, edgePath)` and `internals.resolveEdgeExecutable` is injected for deterministic tests.

## Alternatives considered

- **Leave the handoff to the default browser and rely on Edge's automatic link handling**: zero code, but it depends on Edge being the system default browser, a fixed port that stays inside the installed PWA's scope, and per-install `edge://apps` link-handling settings; none of that is under the invocation's control.
- **Launch the installed PWA's AppUserModelID through `explorer.exe shell:AppsFolder\<AUMID>`**: it opens the PWA's fixed `start_url` and cannot carry the invocation's dynamic port, so it cannot target a running `dsh web` server.
- **Make `browserMode` a deployment-only config with no CLI flag**: the flag is the only way a user launching from a terminal can try the mode without editing a profile; it follows the `--no-open` precedent as an invocation-only override.

## Consequences

- On Windows with Edge installed, `dsh web --browser-mode edge-app` opens the GUI in a standalone application window instead of a browser tab; the PWA question becomes moot because the window is Edge's app-mode shell.
- The opened window is Edge's app-mode shell, not an installed PWA instance: Service Worker scope and install-driven features do not apply.
- `edge-app` on non-Windows or without a resolvable Edge silently degrades to the default browser with one stderr note; there is no hard failure and no new exit path.
- The `--browser-mode` flag joins the validated flag family; an unknown value is rejected before the consumer activates.
- The `resolveEdgeExecutable` helper and the mode propagation are unit-tested without launching Edge, and the CLI browser-open snapshot fixture still receives `(url)` and ignores the extra argv.
