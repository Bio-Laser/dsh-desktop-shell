@echo off
rem DeepSeek Harness - manual debug entry point.
rem The desktop shortcut runs dsh-web.vbs instead, which hides this console.
rem Running this file shows the console and keeps the server in this window.
rem --no-open: the shell owns the window; dsh must not hand the URL to the
rem default browser (the upstream web-app no longer has a browserMode flag).
rem
rem The dsh checkout is not discoverable from this batch file (it is a separate
rem repository), so it must be supplied through DSH_REPO_ROOT.

if not defined DSH_REPO_ROOT (
  echo DSH_REPO_ROOT is not set. Point it at the DeepSeek Harness checkout, e.g.:
  echo   set DSH_REPO_ROOT=D:\DeepSeek-Harness
  echo Or set dshRepoRoot in dsh-shell.config.json.
  exit /b 1
)

if not exist "%DSH_REPO_ROOT%\apps\cli\lib\bin.js" (
  echo apps\cli\lib\bin.js not found under "%DSH_REPO_ROOT%".
  exit /b 1
)

cd /d "%DSH_REPO_ROOT%"
node "%DSH_REPO_ROOT%\apps\cli\lib\bin.js" web --no-open
