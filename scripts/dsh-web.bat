@echo off
rem DeepSeek Harness - manual debug entry point.
rem The desktop shortcut runs dsh-web.vbs instead, which hides this console,
rem opens an Edge app-mode window, and stops dsh when that window closes.
rem Running this file shows the console and keeps the server in this window.
cd /d "%~dp0..\.."
node "%~dp0..\..\apps\cli\lib\bin.js" web --browser-mode edge-app
