Option Explicit

Const APP_TITLE = "PerfFloat Monitor"

Dim fso, shell, scriptDir, monitorPath, command, argument
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
If Len(scriptDir) = 0 Then scriptDir = shell.CurrentDirectory
monitorPath = fso.BuildPath(scriptDir, "PerfFloat.monitor.ps1")

If Not fso.FileExists(monitorPath) Then
    MsgBox "Monitor core not found:" & vbCrLf & monitorPath, vbCritical, APP_TITLE
    WScript.Quit 2
End If

argument = GetArgument()
Select Case argument
    Case "kill", "stop", "exit"
        StopMonitor monitorPath
        WScript.Quit 0
    Case "restart", "reload"
        StopMonitor monitorPath
        WScript.Sleep 500
    Case "config"
        shell.Run "notepad.exe " & Quote(fso.BuildPath(scriptDir, "PerfFloatMonitor.config.ini")), 1, False
        WScript.Quit 0
    Case "help", "?"
        MsgBox "PerfFloat Monitor" & vbCrLf & vbCrLf & _
               "Double-click: start monitor" & vbCrLf & _
               "better.vbs restart: restart" & vbCrLf & _
               "better.vbs kill: exit" & vbCrLf & _
               "better.vbs config: edit config", vbInformation, APP_TITLE
        WScript.Quit 0
End Select

command = "powershell.exe -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(monitorPath)
On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
    MsgBox "Launch failed: " & Err.Description, vbCritical, APP_TITLE
    Err.Clear
End If
On Error GoTo 0

Function GetArgument()
    Dim value
    GetArgument = ""
    If WScript.Arguments.Count = 0 Then Exit Function
    value = LCase(Trim(CStr(WScript.Arguments(0))))
    Do While Left(value, 1) = "-" Or Left(value, 1) = "/"
        value = Mid(value, 2)
        If Len(value) = 0 Then Exit Do
    Loop
    GetArgument = value
End Function

Sub StopMonitor(ByVal path)
    Dim psCommand
    psCommand = "$p='" & Replace(path, "'", "''") & "';" & _
                "Get-CimInstance Win32_Process -Filter ""Name='powershell.exe'"" | " & _
                "Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($p,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | " & _
                "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
    On Error Resume Next
    shell.Run "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " & Quote(psCommand), 0, True
    On Error GoTo 0
End Sub

Function Quote(ByVal value)
    Quote = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
