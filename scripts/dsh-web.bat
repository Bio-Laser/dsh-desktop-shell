@echo off
rem DeepSeek Harness - manual debug entry point.
rem The desktop shortcut runs dsh-web.vbs instead, which hides this console,
rem opens an Edge app-mode window, and stops dsh when that window closes.
rem Running this file shows the console and keeps the server in this window.
rem --no-open: the shell owns the window; dsh must not hand the URL to the
rem default browser (the upstream web-app no longer has a browserMode flag).
cd /d "%~dp0..\.."
node "%~dp0..\..\apps\cli\lib\bin.js" web --no-open
