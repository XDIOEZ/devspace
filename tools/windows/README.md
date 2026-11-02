# DevSpace Manager (Windows)

This WinForms utility displays local DevSpace health, recent tool calls, and cached workspaces. It stays outside the published npm package.

The existing HomeMCP VBS shortcut still launches the local copy outside this repository. Use the command below to run this checked-in version from the DevSpace repository:

~~~powershell
$homeMcpRoot = 'C:\path\to\HomeMCP'
powershell.exe -NoProfile -File .\tools\windows\DevSpaceManager.ps1 -HomeMcpRoot $homeMcpRoot
~~~

Requires Windows PowerShell 5.1. The selected HomeMCP directory must contain the local launcher scripts. The manager reads its DevSpace repository and Node.js paths from Run-DevSpace.ps1, plus the configured state database directory when present. Available HomeMCP logs are displayed; missing logs are skipped. Keep credentials, configuration, state databases, and logs at their locally configured paths and out of Git.
