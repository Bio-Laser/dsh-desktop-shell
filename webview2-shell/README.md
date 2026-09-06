# dsh-web WebView2 shell

This Windows desktop host gives the Web GUI its own process and taskbar identity. It loads the URL passed as its first argument, defaulting to `http://127.0.0.1:3080`; when that URL is not ready, it starts the checkout's `apps/cli/lib/bin.js web --no-open`, waits for readiness, and stops only that child process when the window closes.

Build on Windows with the .NET 8 SDK:

```powershell
dotnet restore native/webview2-shell/WebView2Shell.csproj
dotnet publish native/webview2-shell/WebView2Shell.csproj -c Release -r win-x64 --self-contained false
```

The target machine needs the Evergreen WebView2 Runtime. The published executable is `DeepSeek Harness.exe`, embeds `dsh-web.ico`, and registers the `DeepSeekAI.DeepSeekHarness` AppUserModelID before creating its first window.

Set `DSH_REPO_ROOT` when the published executable cannot discover the checkout from its own directory. The existing PowerShell launcher is not switched to this host until the published executable is available. That keeps the current Edge app-mode path usable during the migration.
