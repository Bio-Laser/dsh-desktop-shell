# dsh-web WebView2 shell

This Windows desktop host gives the Web GUI its own process and taskbar identity. It loads the URL passed as its first argument, defaulting to `http://127.0.0.1:3080`; when no server answers on that URL, it starts the checkout's `apps/cli/lib/bin.js web --no-open`, waits for readiness, and stops only that child process when the window closes.

Readiness means any HTTP response on the URL, including the bearer-token fence's 401 — the response alone proves the server is up. When the shell spawns the server, it navigates to the authenticated URL parsed from the server's `dsh web: <url>` stdout banner, because unauthenticated requests never pass the fence. A server that was already running keeps the configured URL (its stdout is not ours to read); pass the tokenized URL as the first argument in that case.

Build on Windows with the .NET 8 SDK:

```powershell
dotnet restore native/webview2-shell/WebView2Shell.csproj
dotnet publish native/webview2-shell/WebView2Shell.csproj -c Release -r win-x64 --self-contained false
```

The target machine needs the Evergreen WebView2 Runtime. The published executable is `DeepSeek Harness.exe`, embeds `dsh-web.ico`, and registers the `DeepSeekAI.DeepSeekHarness` AppUserModelID before creating its first window.

Set `DSH_REPO_ROOT` when the published executable cannot discover the checkout from its own directory. The existing PowerShell launcher is not switched to this host until the published executable is available. That keeps the current Edge app-mode path usable during the migration.
