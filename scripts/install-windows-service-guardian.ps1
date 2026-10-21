param(
    [Parameter(Mandatory = $true)][string]$StateDir,
    [Parameter(Mandatory = $true)][string]$ConfigDir,
    [string]$NgrokExecutable,
    [string]$NgrokConfig,
    [ValidateSet('ngrok', 'external')][string]$TunnelMode = 'ngrok',
    [string]$TaskName = 'PCC-DevSpace-Guardian'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$node = (Get-Command node.exe -ErrorAction Stop).Source
$wscript = (Get-Command wscript.exe -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot 'windows-service-guardian.mjs'
$launcher = Join-Path $PSScriptRoot 'windows-hidden-launcher.vbs'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$user = $identity.Name
$StateDir = (Resolve-Path -LiteralPath $StateDir).Path
$ConfigDir = (Resolve-Path -LiteralPath $ConfigDir).Path
if ($TunnelMode -eq 'ngrok') {
    if ([string]::IsNullOrWhiteSpace($NgrokExecutable) -or [string]::IsNullOrWhiteSpace($NgrokConfig)) {
        throw 'NgrokExecutable and NgrokConfig are required in ngrok tunnel mode.'
    }
    $NgrokExecutable = (Resolve-Path -LiteralPath $NgrokExecutable).Path
    $NgrokConfig = (Resolve-Path -LiteralPath $NgrokConfig).Path
}

foreach ($path in @($script, $launcher, (Join-Path $StateDir 'devspace.sqlite'), (Join-Path $ConfigDir 'config.jsonc'), (Join-Path $root '.env'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required installation file is missing: $path" }
}

# Keep authorization snapshots and guardian logs readable only by this user and SYSTEM.
function Protect-GuardianDirectory([string]$Path) {
    [void][System.IO.Directory]::CreateDirectory($Path)
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($identity.User)
    foreach ($sid in @($identity.User, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    # Use the DirectoryInfo API so the installer also works on the built-in Windows PowerShell 5.1 runtime.
    $directory = [System.IO.DirectoryInfo]::new($Path)
    $directory.SetAccessControl($acl)
}

$guardianDir = Join-Path $StateDir 'service-guardian'
Protect-GuardianDirectory $guardianDir
Protect-GuardianDirectory (Join-Path $guardianDir 'backups')
$commandArgs = [System.Collections.Generic.List[string]]@(
    '--env-file=' + (Join-Path $root '.env')
    $script
    '--config-dir=' + $ConfigDir
    '--state-dir=' + $StateDir
    '--tunnel-mode=' + $TunnelMode
)
if ($TunnelMode -eq 'ngrok') {
    $commandArgs.Add('--ngrok=' + $NgrokExecutable)
    $commandArgs.Add('--ngrok-config=' + $NgrokConfig)
}
$nodeArguments = ($commandArgs | ForEach-Object {
    if ($_.Contains('"')) { throw 'Installation paths must not contain double quotes.' }
    '"' + $_ + '"'
}) -join ' '
$launcherArguments = @($launcher, $node) + @($commandArgs)
$arguments = ($launcherArguments | ForEach-Object {
    if ($_.Contains('"')) { throw 'Installation paths must not contain double quotes.' }
    '"' + $_ + '"'
}) -join ' '

# Register only this guardian's per-user task; never replace an unrelated existing task.
$scheduler = New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$folder = $scheduler.GetFolder('\')
$existing = $null
foreach ($registered in $folder.GetTasks(0)) {
    if ($registered.Name -eq $TaskName) { $existing = $registered; break }
}
if ($null -ne $existing) {
    $actions = $existing.Definition.Actions
    $isCurrentAction = $actions.Count -eq 1 -and $actions.Item(1).Path -eq $wscript -and $actions.Item(1).Arguments -eq $arguments
    $isLegacyAction = $actions.Count -eq 1 -and $actions.Item(1).Path -eq $node -and $actions.Item(1).Arguments -eq $nodeArguments
    if (-not $isCurrentAction -and -not $isLegacyAction) {
        throw "A different task already uses the name $TaskName. It was not changed."
    }
    $definition = $existing.Definition
} else {
    $definition = $scheduler.NewTask(0)
    $definition.RegistrationInfo.Description = 'Recover stopped local DevSpace processes, optionally supervise the selected tunnel provider, and keep private OAuth-state snapshots.'
    $definition.Principal.UserId = $user
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0
    $definition.Settings.Enabled = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.MultipleInstances = 2
    $definition.Settings.RestartInterval = 'PT1M'
    $definition.Settings.RestartCount = 3
    $trigger = $definition.Triggers.Create(9)
    $trigger.UserId = $user
    $action = $definition.Actions.Create(0)
}

# Launch through the GUI-subsystem WScript host so the long-running Node guardian never owns a visible console.
$action = $definition.Actions.Item(1)
$action.Path = $wscript
$action.Arguments = $arguments
$action.WorkingDirectory = $root

# Recover an exited guardian; IgnoreNew preserves any live instance.
$recoveryTrigger = $null
foreach ($candidate in $definition.Triggers) {
    if ($candidate.Id -eq 'PccGuardianRecovery') { $recoveryTrigger = $candidate; break }
}
if ($null -eq $recoveryTrigger) {
    $recoveryTrigger = $definition.Triggers.Create(1)
    $recoveryTrigger.Id = 'PccGuardianRecovery'
    $recoveryTrigger.StartBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
}
$recoveryTrigger.Enabled = $true
$recoveryTrigger.Repetition.Interval = 'PT1M'
$definition.Settings.MultipleInstances = 2
$registrationMode = if ($null -ne $existing) { 4 } else { 2 }
$task = $folder.RegisterTaskDefinition($TaskName, $definition, $registrationMode, $user, $null, 3)
[void]$task.Run($null)
[pscustomobject]@{ Task = $TaskName; State = $task.State; User = $user; GuardianDirectory = $guardianDir }
