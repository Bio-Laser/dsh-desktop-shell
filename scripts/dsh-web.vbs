' Hidden launcher for the DeepSeek Harness desktop shortcut.
' WScript.Shell.Run with window style 0 starts the PowerShell lifecycle
' script with no visible console window.
Option Explicit

Dim fso, scriptDir, ps1Path, shell
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "dsh-web-hide.ps1")
If Not fso.FileExists(ps1Path) Then
  WScript.Echo "dsh-web-hide.ps1 not found beside " & WScript.ScriptFullName
  WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """", 0, False
