Option Explicit

Dim shell, command, index, argument, exitCode

If WScript.Arguments.Count < 1 Then
    WScript.Quit 87
End If

Set shell = CreateObject("WScript.Shell")
command = QuoteArgument(WScript.Arguments(0))

For index = 1 To WScript.Arguments.Count - 1
    argument = WScript.Arguments(index)
    command = command & " " & QuoteArgument(argument)
Next

' WScript is a GUI-subsystem host, so window style 0 starts the console child without flashing a terminal.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

' Quote one CreateProcess argument; installation paths containing literal quotes are rejected by the installer.
Function QuoteArgument(value)
    QuoteArgument = Chr(34) & CStr(value) & Chr(34)
End Function
