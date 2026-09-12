Option Explicit
' Campus Network Monitor - hidden launcher.
' Double-click this file to open the panel without any console window.
Dim fso, sh, base, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(base, "CampusNetworkMonitor.ps1")
If Not fso.FileExists(ps1) Then
    MsgBox "CampusNetworkMonitor.ps1 was not found next to this file." & vbCrLf & ps1, 16, "Campus Network Monitor"
    WScript.Quit 1
End If
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & ps1 & """"
sh.Run cmd, 0, False
