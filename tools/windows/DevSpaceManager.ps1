#requires -version 5.1
# Pass -HomeMcpRoot to use the local HomeMCP launchers and logs.
param([Parameter(Mandatory = $true)][string]$HomeMcpRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$native = 'using System; using System.Runtime.InteropServices; public static class DevSpaceManagerNative { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd); }'; Add-Type -TypeDefinition $native

$script:HomeRoot = [IO.Path]::GetFullPath($HomeMcpRoot)
$script:DevSpaceBase = 'http://127.0.0.1:7676'
$script:TunnelBase = 'http://127.0.0.1:17676'
$script:DevTask = 'HomeMCP-DevSpace'
$script:TunnelTask = 'HomeMCP-TunnelClient'
$script:StartScript = Join-Path $script:HomeRoot 'Start-HomeMCP-Services.ps1'
$script:DevLauncher = Join-Path $script:HomeRoot 'Run-DevSpace.ps1'
$script:TunnelLauncher = Join-Path $script:HomeRoot 'Run-HomeMCP.ps1'
$script:HiddenLauncher = Join-Path $script:HomeRoot 'Run-Hidden.vbs'
$script:ManagerLog = Join-Path $script:HomeRoot 'DevSpaceManager.log'
$script:TunnelInstall = Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\tunnel-client'
$script:TunnelExe = Join-Path $script:TunnelInstall 'tunnel-client.exe'
$script:TunnelProfileDir = Join-Path $script:TunnelInstall 'profiles'

try {
    $launcherText = Get-Content -LiteralPath $script:DevLauncher -Raw
    $repo = [regex]::Match($launcherText, '(?im)^\s*\$repo\s*=\s*''([^'']+)''')
    $node = [regex]::Match($launcherText, '(?im)^\s*\$node\s*=\s*''([^'']+)''')
    if (!$repo.Success -or !$node.Success) { throw 'Run-DevSpace.ps1 中找不到 DevSpace 路径配置。' }
    $script:DevSpaceRepo = $repo.Groups[1].Value
    $script:DevSpaceNode = $node.Groups[1].Value
    $script:DevSpaceCli = Join-Path $script:DevSpaceRepo 'dist\cli.js'
    $stateDir = [regex]::Match($launcherText, '(?im)^\s*\$env:DEVSPACE_STATE_DIR\s*=\s*''([^'']+)''')
    $script:DevSpaceStateDir = if ($stateDir.Success) { $stateDir.Groups[1].Value } else { Join-Path $env:USERPROFILE '.local\share\devspace' }
    $script:DevSpaceStateDb = Join-Path $script:DevSpaceStateDir 'devspace.sqlite'
} catch {
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'DevSpace Manager', 'OK', 'Error') | Out-Null
    exit 1
}

$script:Color = @{
    Back = [Drawing.ColorTranslator]::FromHtml('#0B1220')
    Card = [Drawing.ColorTranslator]::FromHtml('#121C2D')
    Border = [Drawing.ColorTranslator]::FromHtml('#263449')
    Text = [Drawing.ColorTranslator]::FromHtml('#E5EAF3')
    Muted = [Drawing.ColorTranslator]::FromHtml('#9AAAC1')
    Green = [Drawing.ColorTranslator]::FromHtml('#34D399')
    Yellow = [Drawing.ColorTranslator]::FromHtml('#FBBF24')
    Red = [Drawing.ColorTranslator]::FromHtml('#F87171')
    Log = [Drawing.ColorTranslator]::FromHtml('#0A0F1A')
}
$script:LogSources = @(
    [pscustomobject]@{Name='DevSpace';Path=(Join-Path $script:HomeRoot 'devspace.stdout.log');Severity='INFO'},
    [pscustomobject]@{Name='DevSpace 错误';Path=(Join-Path $script:HomeRoot 'devspace.stderr.log');Severity='ERROR'},
    [pscustomobject]@{Name='启动错误';Path=(Join-Path $script:HomeRoot 'devspace-startup-error.log');Severity='ERROR'},
    [pscustomobject]@{Name='隧道';Path=(Join-Path $script:TunnelInstall 'HomeMCP-autostart.stdout.log');Severity='INFO'},
    [pscustomobject]@{Name='隧道错误';Path=(Join-Path $script:TunnelInstall 'HomeMCP-autostart.stderr.log');Severity='ERROR'},
    [pscustomobject]@{Name='HomeMCP 启动';Path=(Join-Path $script:HomeRoot 'autostart-error.log');Severity='ERROR'},
    [pscustomobject]@{Name='启动状态';Path=(Join-Path $script:HomeRoot 'startup-status.log');Severity='INFO'},
    [pscustomobject]@{Name='Manager';Path=$script:ManagerLog;Severity='INFO'}
)
foreach($source in $script:LogSources){if($source.Name -in @("DevSpace","DevSpace 错误")){$source | Add-Member -NotePropertyName ToolActivity -NotePropertyValue $true}}
$script:LogOffsets=@{};$script:LogBuffers=@{};$script:PendingLogValues=@{}
$script:ToolActivityEntries=[Collections.Generic.List[object]]::new();$script:ToolActivityDirty=$false
$script:WorkspaceEntries=@();$script:WorkspaceActiveCount=0;$script:WorkspaceCacheUpdatedAt=$null;$script:WorkspaceCacheNextRefresh=[DateTime]::MinValue;$script:WorkspaceCacheError='';$script:WorkspaceCacheReady=$false
$script:LastHttpProbe=[DateTime]::MinValue;$script:LastTunnelProbe=[DateTime]::MinValue
$script:ForceProbe=$true;$script:ForceProtocol=$true;$script:OperationBusy=$false;$script:AllowExit=$false
$script:PreviousDevOk=$false;$script:PreviousTunnelOk=$false
$script:DevCrashUntil=[DateTime]::MinValue;$script:TunnelCrashUntil=[DateTime]::MinValue
$script:CachedDevOk=$false;$script:CachedMetaOk=$false;$script:CachedTunnelLive=$false;$script:CachedTunnelReady=$false
$script:CachedPollUnix=0;$script:CachedProxy=-1;$script:CachedProtocol='not_checked';$script:CachedChallenge=$false
$script:Snapshot=$null
$script:HealthRunspace=[RunspaceFactory]::CreateRunspace()
$script:HealthRunspace.ApartmentState='MTA';$script:HealthRunspace.ThreadOptions='ReuseThread';$script:HealthRunspace.Open()
$script:WorkspaceCacheRunspace=[RunspaceFactory]::CreateRunspace();$script:WorkspaceCacheRunspace.ApartmentState="MTA";$script:WorkspaceCacheRunspace.ThreadOptions="ReuseThread";$script:WorkspaceCacheRunspace.Open()
$script:HealthPS=$null;$script:HealthAsync=$null;$script:ActionRunspace=$null;$script:ActionPS=$null;$script:ActionAsync=$null;$script:WorkspaceCachePS=$null;$script:WorkspaceCacheAsync=$null

function Protect-Text([string]$Text) {
    if ($null -eq $Text) { return '' }
    $s=[regex]::Replace($Text,'(?i)(Bearer\s+)[A-Za-z0-9._~+/-]+=*','$1<redacted>')
    $s=[regex]::Replace($s,'(?i)(--?[A-Za-z0-9_-]*(?:token|secret|key|password)\s+)[^\s]+','$1<redacted>')
    $p='(?is)(["'']?\b(?:[A-Za-z0-9_-]*(?:token|secret|key)|password|authorization)\b["'']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|[^\s,;}\]]+)'
    $s=[regex]::Replace($s,$p,'$1<redacted>')
    return [regex]::Replace($s,'(?i)([?&][^=&#]*(?:token|secret|key|password|authorization|code|state)[^=&#]*=)[^&#\s]+','$1<redacted>')
}
function Add-UiLog([string]$Source,[string]$Text,[string]$Default='INFO') {
    if([string]::IsNullOrWhiteSpace($Text)){return}
    $level=$Default.ToUpperInvariant();$message=$Text;$time=(Get-Date).ToString('HH:mm:ss')
    try {
        $entry=$Text|ConvertFrom-Json -ErrorAction Stop
        if($entry.time){try{$time=([DateTimeOffset]::Parse([string]$entry.time)).ToLocalTime().ToString('HH:mm:ss')}catch{}}
        elseif($entry.ts){try{$time=([DateTimeOffset]::Parse([string]$entry.ts)).ToLocalTime().ToString('HH:mm:ss')}catch{}}
        if($entry.level){$level=([string]$entry.level).ToUpperInvariant()}
        if($entry.msg){$message=[string]$entry.msg}
        elseif($entry.event -eq 'http_request'){$message='{0} {1} {2}' -f $entry.method,$entry.path,$entry.status}
        elseif($entry.event){$message=[string]$entry.event}
        if($entry.error){$message+=' | '+[string]$entry.error}
    }catch{}
    if(!$script:PendingLogValues.ContainsKey($Source)){$script:PendingLogValues[$Source]=$false}
    if($script:PendingLogValues[$Source]){
        $indent=[regex]::Match($message,'^\s*').Value
        $comma=if($message -match ',\s*$'){','}else{''}
        $message=$indent+'"<redacted>"'+$comma
        $script:PendingLogValues[$Source]=$false
    }elseif($message -match '(?i)(?:["'']?\b[A-Za-z0-9_-]*(?:token|secret|key|password|authorization)\b["'']?)\s*[:=]\s*$'){
        $script:PendingLogValues[$Source]=$true
    }
    $message=Protect-Text $message
    $message=[regex]::Replace($message,'[\x00-\x08\x0B\x0C\x0E-\x1F]','')
    if($message.Length -gt 600){$message=$message.Substring(0,600)+' …'}
    if(!$script:LogBox){return}
    $color=$script:Color.Muted
    if($level -match 'ERROR|FATAL|PANIC'){$color=$script:Color.Red}
    elseif($level -match 'WARN'){$color=$script:Color.Yellow}
    elseif($level -match 'INFO|DEBUG'){$color=$script:Color.Text}
    $line='{0} [{1}] [{2}] {3}' -f $time,$Source,$level,$message
    $script:LogBox.SelectionStart=$script:LogBox.TextLength;$script:LogBox.SelectionLength=0
    $script:LogBox.SelectionColor=$color;$script:LogBox.AppendText($line+[Environment]::NewLine)
    if($script:LogBox.TextLength -gt 180000){$script:LogBox.Select(0,40000);$script:LogBox.SelectedText=''}
    $script:LogBox.SelectionStart=$script:LogBox.TextLength;$script:LogBox.ScrollToCaret()
}
function Add-ManagerLog([string]$Level,[string]$Message) {
    $line='{0:o} {1} {2}' -f (Get-Date),$Level,(Protect-Text $Message)
    try{[IO.File]::AppendAllText($script:ManagerLog,$line+[Environment]::NewLine,[Text.Encoding]::UTF8);$script:LogOffsets[$script:ManagerLog]=([IO.FileInfo]::new($script:ManagerLog)).Length}catch{}
    Add-UiLog 'Manager' $line $Level
}
function New-Label([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H=24,[float]$Size=10,[Drawing.FontStyle]$Style=[Drawing.FontStyle]::Regular,[Drawing.Color]$Color=$script:Color.Text) {
    $l=[Windows.Forms.Label]::new();$l.Text=$Text;$l.Location=[Drawing.Point]::new($X,$Y);$l.Size=[Drawing.Size]::new($W,$H)
    $l.Font=[Drawing.Font]::new('Microsoft YaHei UI',$Size,$Style);$l.ForeColor=$Color;$l.BackColor=[Drawing.Color]::Transparent
    $l.TextAlign=[Drawing.ContentAlignment]::MiddleLeft;return $l
}
function New-Button([string]$Text,[int]$W,[Drawing.Color]$Back=$script:Color.Card,[Drawing.Color]$Fore=$script:Color.Text) {
    $b=[Windows.Forms.Button]::new();$b.Text=$Text;$b.Size=[Drawing.Size]::new($W,38);$b.Margin=[Windows.Forms.Padding]::new(0,0,9,0)
    $b.BackColor=$Back;$b.ForeColor=$Fore;$b.FlatStyle='Flat';$b.FlatAppearance.BorderColor=$script:Color.Border;$b.FlatAppearance.BorderSize=1
    $b.Font=[Drawing.Font]::new('Microsoft YaHei UI',9);$b.Cursor=[Windows.Forms.Cursors]::Hand;return $b
}
function New-Card([string]$Title) {
    $p=[Windows.Forms.Panel]::new();$p.Dock='Fill';$p.Margin=[Windows.Forms.Padding]::new(4,0,4,0);$p.BackColor=$script:Color.Card;$p.BorderStyle='FixedSingle'
    $t=New-Label $Title 15 10 250 22 9 ([Drawing.FontStyle]::Bold) $script:Color.Muted
    $dot=[Windows.Forms.Panel]::new();$dot.Location=[Drawing.Point]::new(15,43);$dot.Size=[Drawing.Size]::new(10,10);$dot.BackColor=$script:Color.Muted
    $s=New-Label '检测中…' 33 34 255 28 13 ([Drawing.FontStyle]::Bold)
    $d=New-Label '' 15 72 285 43 8 ([Drawing.FontStyle]::Regular) $script:Color.Muted;$d.AutoEllipsis=$true
    $p.Controls.AddRange([Windows.Forms.Control[]]@($t,$dot,$s,$d))
    return [pscustomobject]@{Panel=$p;Dot=$dot;Status=$s;Detail=$d}
}
function Set-Card($Card,[string]$Status,[string]$Detail,[string]$Tone) {
    $Card.Status.Text=$Status;$Card.Detail.Text=$Detail
    $color=switch($Tone){'Green'{$script:Color.Green}'Yellow'{$script:Color.Yellow}'Red'{$script:Color.Red}default{$script:Color.Muted}}
    $Card.Dot.BackColor=$color;$Card.Status.ForeColor=$color
}

$script:ProbeCode = @'
param($DevBase,$TunnelBase,$NodeExe,$Cli,$TunnelExe,$ProfileDir,$ReadHttp,$ReadTunnel,$RunProtocol,$CachedDev,$CachedMeta,$CachedLive,$CachedReady,$CachedPoll,$CachedProxy,$CachedProtocol,$CachedChallenge)
$ErrorActionPreference="SilentlyContinue"
$handler=[System.Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false;$handler.AllowAutoRedirect=$false
$client=[System.Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromMilliseconds(1400)
function Get-Local {
 param($Uri,$Method="GET",$Body="")
 $req=$null;$res=$null;$content='';$contentType='';$challenge='';$errorText=''
 try{
  $verb=[System.Net.Http.HttpMethod]::Get;if($Method -eq "POST"){$verb=[System.Net.Http.HttpMethod]::Post}
  $req=[System.Net.Http.HttpRequestMessage]::new($verb,$Uri)
  if($Method -eq "POST"){$req.Headers.Accept.ParseAdd("application/json");$req.Headers.Accept.ParseAdd("text/event-stream");$req.Content=[System.Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,"application/json")}
  $send=$client.SendAsync($req,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
  if(!$send.Wait(1500)){throw [TimeoutException]::new('Response headers timed out.')}
  $res=$send.GetAwaiter().GetResult()
  if($res.Headers.WwwAuthenticate){$challenge=$res.Headers.WwwAuthenticate.ToString()}
  if($res.Content.Headers.ContentType){$contentType=$res.Content.Headers.ContentType.MediaType}
  if($contentType -eq 'text/event-stream'){$errorText='stream_not_read'}
  else{$read=$res.Content.ReadAsStringAsync();if($read.Wait(1000)){$content=$read.GetAwaiter().GetResult()}else{$errorText='response_body_timeout'}}
  return [pscustomobject]@{Status=[int]$res.StatusCode;Body=$content;Challenge=$challenge;ContentType=$contentType;Error=$errorText}
 }catch{
  $status=0;if($res){$status=[int]$res.StatusCode}
  return [pscustomobject]@{Status=$status;Body=$content;Challenge=$challenge;ContentType=$contentType;Error=$_.Exception.GetBaseException().Message}
 }finally{if($res){$res.Dispose()};if($req){$req.Dispose()}}
}
function Test-Port([int]$Port){
 $tcp=[Net.Sockets.TcpClient]::new()
 try{$work=$tcp.ConnectAsync("127.0.0.1",$Port);return ($work.Wait(450)-and $tcp.Connected)}catch{return $false}finally{$tcp.Dispose()}
}
function Get-Uptime([int]$Id){
 try{$proc=Get-Process -Id $Id -ErrorAction Stop;$started=[DateTimeOffset]::new($proc.StartTime.ToUniversalTime());return [Math]::Max(0,[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$started.ToUnixTimeSeconds())}catch{return -1}
}
$all=@(Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='tunnel-client.exe' OR Name='powershell.exe' OR Name='wscript.exe'")
$devPattern=('(?i)^\s*"?{0}"?\s+"?{1}"?\s+serve(?=\s|$)' -f [regex]::Escape($NodeExe),[regex]::Escape($Cli))
$tunnelPattern=('(?i)^\s*"?{0}"?\s+run\s+--profile\s+"?HomePC"?\s+--profile-dir\s+"?{1}"?(?=\s|$)' -f [regex]::Escape($TunnelExe),[regex]::Escape($ProfileDir))
$dev=@($all|Where-Object{$_.Name -ieq 'node.exe' -and $_.ExecutablePath -ieq $NodeExe -and $_.CommandLine -match $devPattern})
$tunnel=@($all|Where-Object{$_.Name -ieq 'tunnel-client.exe' -and $_.ExecutablePath -ieq $TunnelExe -and $_.CommandLine -match $tunnelPattern})
$devPid=0;$devUptime=-1;if($dev.Count -eq 1){$devPid=[int]$dev[0].ProcessId;$devUptime=Get-Uptime $devPid}
$tunPid=0;$tunUptime=-1;if($tunnel.Count -eq 1){$tunPid=[int]$tunnel[0].ProcessId;$tunUptime=Get-Uptime $tunPid}
$devTcp=Test-Port 7676;$tunTcp=Test-Port 17676;$devOk=$CachedDev;$metaOk=$CachedMeta
if($ReadHttp){
 $health=Get-Local "$DevBase/healthz";$res=Get-Local "$DevBase/.well-known/oauth-protected-resource/mcp";$oauth=Get-Local "$DevBase/.well-known/oauth-authorization-server"
 $devOk=$false;$metaOk=$false
 if($health.Status -eq 200 -and $res.Status -eq 200 -and $oauth.Status -eq 200){
  try{$hj=$health.Body|ConvertFrom-Json;$rj=$res.Body|ConvertFrom-Json;$oj=$oauth.Body|ConvertFrom-Json
   $devOk=($hj.ok -eq $true -and $hj.name -eq 'devspace')
   $metaOk=($rj.resource -eq "$DevBase/mcp" -and $oj.issuer -eq "$DevBase/" -and $oj.authorization_endpoint -eq "$DevBase/authorize" -and $oj.token_endpoint -eq "$DevBase/token")
  }catch{}
 }
}
$protocol=$CachedProtocol;$challengeOk=$CachedChallenge
if($RunProtocol){
 $body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"DevSpaceManager","version":"1.0"}}}'
 $mcp=Get-Local "$DevBase/mcp" 'POST' $body
 if($mcp.Status -eq 401 -and $mcp.Challenge -match '(?i)Bearer'){$protocol='oauth_required';$challengeOk=$true}
 elseif($mcp.Status -eq 200){
  $protocol='invalid_response';$challengeOk=$false;$payload=$mcp.Body
  if($mcp.ContentType -eq 'text/event-stream'){$protocol='stream_unverified';$payload=''}
  elseif($mcp.Error -eq 'response_body_timeout'){$protocol='body_timeout';$payload=''}
  if(![string]::IsNullOrWhiteSpace($payload)){
   try{$reply=$payload|ConvertFrom-Json -ErrorAction Stop
    if($reply.jsonrpc -eq '2.0' -and $reply.id -eq 1 -and $null -ne $reply.result){$protocol='responded'}
    elseif($reply.jsonrpc -eq '2.0' -and $reply.id -eq 1 -and $null -ne $reply.error){$protocol='jsonrpc_error'}
   }catch{}
  }
}
 elseif($mcp.Status -gt 0){$protocol="http_$($mcp.Status)";$challengeOk=$false}
 else{$protocol='unreachable';$challengeOk=$false}
}
$live=$CachedLive;$ready=$CachedReady;$lastPoll=$CachedPoll;$proxy=$CachedProxy
if($ReadTunnel){
 $h=Get-Local "$TunnelBase/healthz";$r=Get-Local "$TunnelBase/readyz";$metrics=Get-Local "$TunnelBase/metrics"
 $live=($h.Status -eq 200 -and $h.Body.Trim() -eq 'live');$ready=($r.Status -eq 200 -and $r.Body.Trim().StartsWith('ready'));$lastPoll=0;$proxy=-1
 if($metrics.Status -eq 200){foreach($line in ($metrics.Body -split '\r?\n')){
  if($line -match '^commands_poll_last_successful_timestamp_seconds(?:\{[^}]*\})?\s+([0-9.eE+-]+)'){try{$lastPoll=[long][double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}catch{}}
  if($line -match '^proxy_health_state(?:\{[^}]*\})?\s+([0-9.eE+-]+)'){try{$proxy=[int][double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}catch{}}
 }}
}
$age=-1;if($lastPoll -gt 0){$age=[Math]::Max(0,[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-$lastPoll)}
$taskDev=$false;$taskTunnel=$false
try{$taskDev=(Get-ScheduledTask -TaskName 'HomeMCP-DevSpace').Settings.Enabled}catch{}
try{$taskTunnel=(Get-ScheduledTask -TaskName 'HomeMCP-TunnelClient').Settings.Enabled}catch{}
[pscustomobject]@{
 DevCount=$dev.Count;DevPid=$devPid;DevUptime=$devUptime;DevTcp=$devTcp;DevOk=$devOk;McpMeta=$metaOk
 Protocol=$protocol;Challenge=$challengeOk;RunProtocol=$RunProtocol;TunnelCount=$tunnel.Count;TunnelPid=$tunPid;TunnelUptime=$tunUptime
 TunnelTcp=$tunTcp;TunnelLive=$live;TunnelReady=$ready;PollAge=$age;PollLast=$lastPoll;Proxy=$proxy
 TaskDev=$taskDev;TaskTunnel=$taskTunnel;ReadHttp=$ReadHttp;ReadTunnel=$ReadTunnel
}
$client.Dispose();$handler.Dispose()
'@

$script:ActionCode = @'
param($Action,$HomeRoot,$NodeExe,$Cli,$TunnelExe,$ProfileDir,$DevBase,$TunnelBase,$StartScript)
$ErrorActionPreference='Stop'
$DevTask='HomeMCP-DevSpace';$TunnelTask='HomeMCP-TunnelClient'
$DevRunner=Join-Path $HomeRoot 'Run-DevSpace.ps1';$TunnelRunner=Join-Path $HomeRoot 'Run-HomeMCP.ps1';$Wrapper=Join-Path $HomeRoot 'Run-Hidden.vbs'
function Get-Targets {
 $all=@(Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='tunnel-client.exe' OR Name='powershell.exe' OR Name='wscript.exe'")
 $nodePattern=('(?i)^\s*"?{0}"?\s+"?{1}"?\s+serve(?=\s|$)' -f [regex]::Escape($NodeExe),[regex]::Escape($Cli))
 $tunnelPattern=('(?i)^\s*"?{0}"?\s+run\s+--profile\s+"?HomePC"?\s+--profile-dir\s+"?{1}"?(?=\s|$)' -f [regex]::Escape($TunnelExe),[regex]::Escape($ProfileDir))
 $PowerShellExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $WScriptExe=Join-Path $env:SystemRoot 'System32\wscript.exe'
 $devRunnerPattern=('(?i)^\s*"?{0}"?\s+-NoProfile\s+-NonInteractive\s+-ExecutionPolicy\s+Bypass\s+-File\s+"?{1}"?(?=\s|$)' -f [regex]::Escape($PowerShellExe),[regex]::Escape($DevRunner))
 $tunnelRunnerPattern=('(?i)^\s*"?{0}"?\s+-NoProfile\s+-NonInteractive\s+-ExecutionPolicy\s+Bypass\s+-File\s+"?{1}"?(?=\s|$)' -f [regex]::Escape($PowerShellExe),[regex]::Escape($TunnelRunner))
 $wrapperPattern=('(?i)^\s*"?{0}"?\s+//B\s+//Nologo\s+"?{1}"?\s+"?(?:Run-DevSpace|Run-HomeMCP)\.ps1"?(?=\s|$)' -f [regex]::Escape($WScriptExe),[regex]::Escape($Wrapper))
 $found=[System.Collections.Generic.List[object]]::new()
 foreach($p in $all){
  if($p.Name -ieq 'node.exe' -and $p.ExecutablePath -ieq $NodeExe -and $p.CommandLine -match $nodePattern){$found.Add([pscustomobject]@{Kind='DevSpace';Id=[int]$p.ProcessId})}
  elseif($p.Name -ieq 'tunnel-client.exe' -and $p.ExecutablePath -ieq $TunnelExe -and $p.CommandLine -match $tunnelPattern){$found.Add([pscustomobject]@{Kind='Tunnel';Id=[int]$p.ProcessId})}
  elseif($p.Name -ieq 'powershell.exe' -and $p.ExecutablePath -ieq $PowerShellExe -and ($p.CommandLine -match $devRunnerPattern -or $p.CommandLine -match $tunnelRunnerPattern)){$found.Add([pscustomobject]@{Kind='Runner';Id=[int]$p.ProcessId})}
  elseif($p.Name -ieq 'wscript.exe' -and $p.ExecutablePath -ieq $WScriptExe -and $p.CommandLine -match $wrapperPattern){$found.Add([pscustomobject]@{Kind='Launcher';Id=[int]$p.ProcessId})}
 }
 return @($found)
}
function Get-Local([string]$Uri){
 $h=[System.Net.Http.HttpClientHandler]::new();$h.UseProxy=$false;$c=[System.Net.Http.HttpClient]::new($h);$c.Timeout=[TimeSpan]::FromMilliseconds(1800)
 try{$r=$c.GetAsync($Uri).GetAwaiter().GetResult();$b=$r.Content.ReadAsStringAsync().GetAwaiter().GetResult();return [pscustomobject]@{Status=[int]$r.StatusCode;Body=$b}}
 catch{return [pscustomobject]@{Status=0;Body=$_.Exception.GetBaseException().Message}}finally{$c.Dispose();$h.Dispose()}
}
function Test-Port([int]$Port){
 $tcp=[Net.Sockets.TcpClient]::new()
 try{$attempt=$tcp.ConnectAsync('127.0.0.1',$Port);return ($attempt.Wait(500)-and $tcp.Connected)}catch{return $false}finally{$tcp.Dispose()}
}
function Get-TunnelState {
 $h=Get-Local "$TunnelBase/healthz";$r=Get-Local "$TunnelBase/readyz";$m=Get-Local "$TunnelBase/metrics";$age=-1;$proxy=-1
 if($m.Status -eq 200){foreach($line in ($m.Body -split '\r?\n')){
  if($line -match '^commands_poll_last_successful_timestamp_seconds(?:\{[^}]*\})?\s+([0-9.eE+-]+)'){try{$last=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture);$age=[Math]::Max(0,[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[long]$last)}catch{}}
  if($line -match '^proxy_health_state(?:\{[^}]*\})?\s+([0-9.eE+-]+)'){try{$proxy=[int][double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}catch{}}
 }}
 return [pscustomobject]@{Live=($h.Status -eq 200 -and $h.Body.Trim() -eq 'live');Ready=($r.Status -eq 200 -and $r.Body.Trim().StartsWith('ready'));Age=$age;Proxy=$proxy}
}
function Stop-HomeMcp {
 $before=@(Get-Targets)
 $knownDev=@($before|Where-Object{$_.Kind -eq 'DevSpace'}).Count
  $knownTunnel=@($before|Where-Object{$_.Kind -eq 'Tunnel'}).Count
  $busyDev=Test-Port 7676;$busyTunnel=Test-Port 17676
  if(($busyDev -and $knownDev -eq 0) -or ($busyTunnel -and $knownTunnel -eq 0)){throw '服务端口仍在监听，但对应 HomeMCP 进程未识别；未更改任务或停止其他进程。'}
 foreach($name in @($DevTask,$TunnelTask)){try{Disable-ScheduledTask -TaskName $name -ErrorAction Stop|Out-Null}catch{if($_.Exception.Message -notmatch 'cannot find|does not exist'){throw}}}
 foreach($name in @($DevTask,$TunnelTask)){try{Stop-ScheduledTask -TaskName $name -ErrorAction Stop|Out-Null}catch{}}
 $targets=@(Get-Targets)
 foreach($kind in @('Tunnel','DevSpace','Runner','Launcher')){
  foreach($target in @($targets|Where-Object{$_.Kind -eq $kind})){
   if(@(Get-Targets|Where-Object{$_.Id -eq $target.Id -and $_.Kind -eq $target.Kind}).Count -gt 0){try{Stop-Process -Id $target.Id -Force -ErrorAction Stop}catch{}}
  }
 }
 $deadline=[DateTime]::UtcNow.AddSeconds(12)
 do{Start-Sleep -Milliseconds 500;$remaining=@(Get-Targets)}while($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
 if($remaining.Count -gt 0){$ids=($remaining|ForEach-Object{$_.Id}) -join ', ';throw "HomeMCP 进程未全部停止；残留 PID: $ids"}
 $devPortBusy=Test-Port 7676;$tunnelPortBusy=Test-Port 17676
  if($devPortBusy -or $tunnelPortBusy){
   $ports=@();if($devPortBusy){$ports+='7676'};if($tunnelPortBusy){$ports+='17676'}
   throw "匹配的 HomeMCP 进程已停止，但端口 $($ports -join ', ') 仍在监听；归属未知，未操作其他进程。"
  }
  return '已停止 DevSpace 和隧道；相关计划任务已暂停。'
}
function Start-HomeMcp {
 $before=@(Get-Targets);$devCount=@($before|Where-Object{$_.Kind -eq 'DevSpace'}).Count;$tunCount=@($before|Where-Object{$_.Kind -eq 'Tunnel'}).Count
 if($devCount -gt 1 -or $tunCount -gt 1){$ids=($before|Where-Object{$_.Kind -in @('DevSpace','Tunnel')}|ForEach-Object{$_.Id}) -join ', ';throw "检测到重复服务实例（PID: $ids）；未启动。"}
 $dev=Get-Local "$DevBase/healthz";$tun=Get-TunnelState
 if($devCount -eq 1 -and $tunCount -eq 1){
  if($dev.Status -ne 200 -or !$tun.Live -or !$tun.Ready -or $tun.Age -lt 0 -or $tun.Age -gt 90 -or $tun.Proxy -ne 1){throw '进程仍在但健康检查失败；未重复启动。请使用“重启服务”。'}
  foreach($name in @($DevTask,$TunnelTask)){$task=Get-ScheduledTask -TaskName $name -ErrorAction Stop;if(!$task.Settings.Enabled){Enable-ScheduledTask -TaskName $name -ErrorAction Stop|Out-Null}}
  return '两项服务已健康运行；跳过重复启动。'
 }
 if($devCount -eq 0 -and (Test-Port 7676)){throw '7676 端口已有响应但进程归属不明；为避免重复启动，已停止。'}
 if($tunCount -eq 0 -and (Test-Port 17676)){throw '17676 端口已有响应但进程归属不明；为避免重复启动，已停止。'}
 foreach($name in @($DevTask,$TunnelTask)){$task=Get-ScheduledTask -TaskName $name -ErrorAction Stop;if(!$task.Settings.Enabled){Enable-ScheduledTask -TaskName $name -ErrorAction Stop|Out-Null}}
 & $StartScript
  $deadline=[DateTime]::UtcNow.AddSeconds(240);$devReady=$false;$tunnelReady=$false
 do{
  $h=Get-Local "$DevBase/healthz";$r=Get-Local "$DevBase/.well-known/oauth-protected-resource/mcp";$o=Get-Local "$DevBase/.well-known/oauth-authorization-server"
  $devReady=($h.Status -eq 200 -and $r.Status -eq 200 -and $o.Status -eq 200)
  $t=Get-TunnelState;$tunnelReady=($t.Live -and $t.Ready -and $t.Age -ge 0 -and $t.Age -le 90 -and $t.Proxy -eq 1)
  if($devReady -and $tunnelReady){break};Start-Sleep -Seconds 2
 }while([DateTime]::UtcNow -lt $deadline)
  if(!$devReady){throw 'DevSpace 尚未确认就绪：240 秒内 health 和 OAuth discovery 未通过；后台进程可能仍在启动，请查看服务错误日志。'}
  if(!$tunnelReady){return 'DevSpace 已就绪；240 秒内尚未确认隧道控制面轮询，后台隧道可能仍在启动，请查看隧道日志。'}
 return 'DevSpace、MCP OAuth discovery 和 HomePC 隧道均已就绪。'
}
$operationMutex=$null;$ownsMutex=$false
try{
 $operationMutex=[System.Threading.Mutex]::new($false,'Local\HomeMCP-DevSpaceManager-Action')
 try{$ownsMutex=$operationMutex.WaitOne(0)}catch [System.Threading.AbandonedMutexException]{$ownsMutex=$true}
 if(!$ownsMutex){throw '另一个 DevSpace Manager 正在执行服务操作，请稍后再试。'}
 switch($Action){'Start'{$message=Start-HomeMcp};'Stop'{$message=Stop-HomeMcp};'Restart'{$a=Stop-HomeMcp;$b=Start-HomeMcp;$message="$a $b"};default{throw "未知操作: $Action"}}
 $level=if($message -match '未确认|请查看'){ 'WARN' }else{ 'INFO' }
 [pscustomobject]@{Success=$true;Message=$message;Severity=$level}
}catch{[pscustomobject]@{Success=$false;Message=$_.Exception.GetBaseException().Message;Severity='ERROR'}}
finally{if($ownsMutex){try{$operationMutex.ReleaseMutex()}catch{}};if($operationMutex){$operationMutex.Dispose()}}
'@

$script:WorkspaceCacheCode = @'
param($NodeExe,$Repo,$DbPath)
$ErrorActionPreference="Stop"
$dbPathJson=ConvertTo-Json -InputObject $DbPath -Compress
$nodeCode=@"
const fs = require("node:fs");
const Database = require("better-sqlite3");
const db = new Database($dbPathJson, { readonly: true, fileMustExist: true });
try {
  db.pragma("query_only = ON");
  const activeCount = db.prepare("SELECT count(*) AS count FROM workspace_sessions WHERE status = 'active'").get().count;
  const rows = db.prepare("SELECT id, root, mode, last_used_at FROM workspace_sessions WHERE status = 'active' ORDER BY last_used_at DESC LIMIT 32").all();
  const entries = rows.map((row) => {
    let directoryExists = false;
    try { directoryExists = fs.statSync(row.root).isDirectory(); } catch {}
    return { id: row.id, rootBase64: Buffer.from(row.root, "utf8").toString("base64"), mode: row.mode, lastUsedAt: row.last_used_at, directoryExists };
  });
  console.log(JSON.stringify({ activeCount, entries }));
} finally {
  db.close();
}
"@
$startInfo=[Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName=$NodeExe;$startInfo.Arguments="-";$startInfo.WorkingDirectory=$Repo
$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
$startInfo.RedirectStandardInput=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true

$nodeProcess=$null
try{
 $nodeProcess=[Diagnostics.Process]::Start($startInfo)
 $stdoutTask=$nodeProcess.StandardOutput.ReadToEndAsync();$stderrTask=$nodeProcess.StandardError.ReadToEndAsync()
 $nodeProcess.StandardInput.Write($nodeCode);$nodeProcess.StandardInput.Close()
 if(!$nodeProcess.WaitForExit(15000)){try{$nodeProcess.Kill()}catch{};throw "SQLite 查询超过 15 秒。"}
 $nodeOutput=$stdoutTask.GetAwaiter().GetResult();$nodeError=$stderrTask.GetAwaiter().GetResult();$nodeExitCode=$nodeProcess.ExitCode
}finally{if($nodeProcess){if(!$nodeProcess.HasExited){try{$nodeProcess.Kill()}catch{}};$nodeProcess.Dispose()}}
if($nodeExitCode -ne 0){throw ("better-sqlite3 查询失败："+$nodeError.Trim())}
return ($nodeOutput|ConvertFrom-Json -ErrorAction Stop)
'@

$script:Form=[Windows.Forms.Form]::new();$script:Form.Text='DevSpace Manager';$script:Form.StartPosition='CenterScreen';$script:Form.ShowInTaskbar=$true
$script:Form.ClientSize=[Drawing.Size]::new(1030,730);$script:Form.FormBorderStyle='FixedDialog';$script:Form.MaximizeBox=$false
$script:Form.BackColor=$script:Color.Back;$script:Form.ForeColor=$script:Color.Text;$script:Form.Font=[Drawing.Font]::new('Microsoft YaHei UI',9)
$script:Tabs=[Windows.Forms.TabControl]::new();$script:Tabs.Dock='Fill';$script:Tabs.DrawMode='OwnerDrawFixed';$script:Tabs.SizeMode='Fixed';$script:Tabs.ItemSize=[Drawing.Size]::new(170,30);$script:Tabs.BackColor=$script:Color.Back
$script:DashboardPage=[Windows.Forms.TabPage]::new();$script:DashboardPage.Text='服务概览';$script:DashboardPage.BackColor=$script:Color.Back;$script:DashboardPage.UseVisualStyleBackColor=$false
$script:ActivityPage=[Windows.Forms.TabPage]::new();$script:ActivityPage.Text='AI 调用 / 工作区';$script:ActivityPage.BackColor=$script:Color.Back;$script:ActivityPage.UseVisualStyleBackColor=$false
$script:Tabs.Add_DrawItem({
    param($sender,$e)
    $selected=($e.Index -eq $sender.SelectedIndex)
    $background=if($selected){$script:Color.Card}else{$script:Color.Back}
    $foreground=if($selected){$script:Color.Text}else{$script:Color.Muted}
    $backBrush=[Drawing.SolidBrush]::new($background);$textBrush=[Drawing.SolidBrush]::new($foreground)
    $format=[Drawing.StringFormat]::new();$format.Alignment=[Drawing.StringAlignment]::Center;$format.LineAlignment=[Drawing.StringAlignment]::Center
    try {
        $e.Graphics.FillRectangle($backBrush,$e.Bounds)
        $bounds=[Drawing.RectangleF]::new([single]$e.Bounds.X,[single]$e.Bounds.Y,[single]$e.Bounds.Width,[single]$e.Bounds.Height)
        $e.Graphics.DrawString($sender.TabPages[$e.Index].Text,$script:Form.Font,$textBrush,$bounds,$format)
    } finally {
        $backBrush.Dispose();$textBrush.Dispose();$format.Dispose()
    }
})
$layout=[Windows.Forms.TableLayoutPanel]::new();$layout.Dock='Fill';$layout.Padding=[Windows.Forms.Padding]::new(18,14,18,14);$layout.ColumnCount=1;$layout.RowCount=6
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
$heights=@(64,140,52,39,100,25)
for($i=0;$i -lt $heights.Count;$i++){$type=if($i -eq 4){[Windows.Forms.SizeType]::Percent}else{[Windows.Forms.SizeType]::Absolute};[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new($type,[single]$heights[$i]))}
$script:DashboardPage.Controls.Add($layout)
$header=[Windows.Forms.Panel]::new();$header.Dock='Fill'
$title=New-Label 'DevSpace Manager' 0 0 420 34 19 ([Drawing.FontStyle]::Bold)
$subtitle=New-Label 'HomeMCP · DevSpace + HomePC 隧道' 2 35 470 21 9 ([Drawing.FontStyle]::Regular) $script:Color.Muted
$header.Controls.AddRange([Windows.Forms.Control[]]@($title,$subtitle));$layout.Controls.Add($header,0,0)
$grid=[Windows.Forms.TableLayoutPanel]::new();$grid.Dock='Fill';$grid.ColumnCount=3;$grid.RowCount=1
for($i=0;$i -lt 3;$i++){[void]$grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,33.333))}
[void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
$script:DevCard=New-Card 'DevSpace';$script:McpCard=New-Card 'MCP';$script:TunnelCard=New-Card 'HomePC 隧道'
$grid.Controls.Add($script:DevCard.Panel,0,0);$grid.Controls.Add($script:McpCard.Panel,1,0);$grid.Controls.Add($script:TunnelCard.Panel,2,0);$layout.Controls.Add($grid,0,1)
$actions=[Windows.Forms.FlowLayoutPanel]::new();$actions.Dock='Fill';$actions.FlowDirection='LeftToRight';$actions.WrapContents=$false;$actions.Padding=[Windows.Forms.Padding]::new(0,6,0,0)
$script:StartButton=New-Button '启动服务' 105 ([Drawing.ColorTranslator]::FromHtml('#1D4ED8')) ([Drawing.Color]::White)
$script:StopButton=New-Button '停止服务' 105;$script:RestartButton=New-Button '重启服务' 105;$script:DiagnoseButton=New-Button '一键诊断' 105;$script:OpenLogsButton=New-Button '查看日志' 105
$actions.Controls.AddRange([Windows.Forms.Control[]]@($script:StartButton,$script:StopButton,$script:RestartButton,$script:DiagnoseButton,$script:OpenLogsButton));$layout.Controls.Add($actions,0,2)
$logHead=[Windows.Forms.Panel]::new();$logHead.Dock='Fill';$label=New-Label '实时日志' 0 1 100 30 10 ([Drawing.FontStyle]::Bold)
$script:LogCombo=[Windows.Forms.ComboBox]::new();$script:LogCombo.DropDownStyle='DropDownList';$script:LogCombo.FlatStyle='Flat';$script:LogCombo.BackColor=$script:Color.Card;$script:LogCombo.ForeColor=$script:Color.Text
$script:LogCombo.Font=[Drawing.Font]::new('Microsoft YaHei UI',8);$script:LogCombo.Location=[Drawing.Point]::new(104,4);$script:LogCombo.Size=[Drawing.Size]::new(205,28)
foreach($source in $script:LogSources){[void]$script:LogCombo.Items.Add($source)};$script:LogCombo.DisplayMember='Name';$script:LogCombo.SelectedIndex=0
$script:CopyButton=New-Button '复制' 68;$script:CopyButton.Height=30;$script:CopyButton.Location=[Drawing.Point]::new(620,3)
$script:ClearButton=New-Button '清空显示' 85;$script:ClearButton.Height=30;$script:ClearButton.Location=[Drawing.Point]::new(694,3)
$script:FullLogButton=New-Button '查看完整日志' 112;$script:FullLogButton.Height=30;$script:FullLogButton.Location=[Drawing.Point]::new(785,3)
$logHead.Controls.AddRange([Windows.Forms.Control[]]@($label,$script:LogCombo,$script:CopyButton,$script:ClearButton,$script:FullLogButton));$layout.Controls.Add($logHead,0,3)
$script:LogBox=[Windows.Forms.RichTextBox]::new();$script:LogBox.Dock='Fill';$script:LogBox.ReadOnly=$true;$script:LogBox.DetectUrls=$false;$script:LogBox.WordWrap=$false
$script:LogBox.BackColor=$script:Color.Log;$script:LogBox.ForeColor=$script:Color.Text;$script:LogBox.BorderStyle='FixedSingle';$script:LogBox.Font=[Drawing.Font]::new('Consolas',9);$script:LogBox.HideSelection=$false;$script:LogBox.MaxLength=200000
$layout.Controls.Add($script:LogBox,0,4)
$script:Footer=New-Label '每 2 秒刷新状态 · 关闭管理器不影响后台服务' 0 0 980 24 8 ([Drawing.FontStyle]::Regular) $script:Color.Muted;$layout.Controls.Add($script:Footer,0,5)

$activityLayout=[Windows.Forms.TableLayoutPanel]::new();$activityLayout.Dock='Fill';$activityLayout.Padding=[Windows.Forms.Padding]::new(18,12,18,12);$activityLayout.ColumnCount=1;$activityLayout.RowCount=5
[void]$activityLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
foreach($row in @([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,30),[Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,49),[Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,58),[Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,51),[Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,22))){[void]$activityLayout.RowStyles.Add($row)}
$callHeader=[Windows.Forms.Panel]::new();$callHeader.Dock='Fill'
$callTitle=New-Label 'AI / MCP 工具调用' 0 0 190 28 10 ([Drawing.FontStyle]::Bold)
$script:CallSummary=New-Label '等待 DevSpace 调用记录…' 190 1 650 26 8 ([Drawing.FontStyle]::Regular) $script:Color.Muted
$callHeader.Controls.AddRange([Windows.Forms.Control[]]@($callTitle,$script:CallSummary));$activityLayout.Controls.Add($callHeader,0,0)
$script:ToolCallList=[Windows.Forms.ListView]::new();$script:ToolCallList.Dock='Fill';$script:ToolCallList.View='Details';$script:ToolCallList.FullRowSelect=$true;$script:ToolCallList.GridLines=$true;$script:ToolCallList.HideSelection=$false;$script:ToolCallList.BorderStyle='FixedSingle';$script:ToolCallList.BackColor=$script:Color.Log;$script:ToolCallList.ForeColor=$script:Color.Text;$script:ToolCallList.Font=[Drawing.Font]::new('Consolas',9)
[void]$script:ToolCallList.Columns.Add('时间',125);[void]$script:ToolCallList.Columns.Add('操作',95);[void]$script:ToolCallList.Columns.Add('MCP 方法',170);[void]$script:ToolCallList.Columns.Add('工作区 ID',130);[void]$script:ToolCallList.Columns.Add('结果',75);[void]$script:ToolCallList.Columns.Add('耗时',85)
$activityLayout.Controls.Add($script:ToolCallList,0,1)
$cacheHeader=[Windows.Forms.Panel]::new();$cacheHeader.Dock='Fill'
$cacheTitle=New-Label '工作区缓存' 0 0 125 24 10 ([Drawing.FontStyle]::Bold)
$script:WorkspaceCacheSummary=New-Label '正在读取活跃工作区…' 130 1 820 22 8 ([Drawing.FontStyle]::Regular) $script:Color.Muted
$script:WorkspaceCacheNote=New-Label '显示最近 32 条 active 持久会话及目录状态；依据更新时间推定 LRU 候选，不代表当前内存驻留。' 0 27 950 20 8 ([Drawing.FontStyle]::Regular) $script:Color.Muted
$cacheHeader.Controls.AddRange([Windows.Forms.Control[]]@($cacheTitle,$script:WorkspaceCacheSummary,$script:WorkspaceCacheNote));$activityLayout.Controls.Add($cacheHeader,0,2)
$script:WorkspaceCacheList=[Windows.Forms.ListView]::new();$script:WorkspaceCacheList.Dock='Fill';$script:WorkspaceCacheList.View='Details';$script:WorkspaceCacheList.FullRowSelect=$true;$script:WorkspaceCacheList.GridLines=$true;$script:WorkspaceCacheList.HideSelection=$false;$script:WorkspaceCacheList.ShowItemToolTips=$true;$script:WorkspaceCacheList.BorderStyle='FixedSingle';$script:WorkspaceCacheList.BackColor=$script:Color.Log;$script:WorkspaceCacheList.ForeColor=$script:Color.Text;$script:WorkspaceCacheList.Font=[Drawing.Font]::new('Consolas',9)
[void]$script:WorkspaceCacheList.Columns.Add('工作区 ID',130);[void]$script:WorkspaceCacheList.Columns.Add('工作目录',455);[void]$script:WorkspaceCacheList.Columns.Add('模式',105);[void]$script:WorkspaceCacheList.Columns.Add('目录状态',85);[void]$script:WorkspaceCacheList.Columns.Add('最近使用',150)
$activityLayout.Controls.Add($script:WorkspaceCacheList,0,3)
$activityFooter=New-Label '仅显示服务已记录的调用；日志不区分本地或隧道来源，参数与文件内容均隐藏。' 0 0 950 20 8 ([Drawing.FontStyle]::Regular) $script:Color.Muted;$activityLayout.Controls.Add($activityFooter,0,4)
$script:ActivityPage.Controls.Add($activityLayout)
[void]$script:Tabs.TabPages.Add($script:DashboardPage);[void]$script:Tabs.TabPages.Add($script:ActivityPage);$script:Form.Controls.Add($script:Tabs)

function Get-UptimeText([long]$Seconds) {
 if($Seconds -lt 0){return '运行时长未知'};$span=[TimeSpan]::FromSeconds($Seconds)
 if($span.TotalDays -ge 1){return '{0}天 {1:00}:{2:00}:{3:00}' -f [int][Math]::Floor($span.TotalDays),$span.Hours,$span.Minutes,$span.Seconds}
 return '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds
}
function Get-ToolActionLabel([string]$Tool) {
 switch -Regex ($Tool) {
  '^open_workspace$' {'打开工作区';break}
  '^download_artifact$' {'导入文件';break}
  '^(read|list|search|find)(_|$)' {'读取 / 搜索';break}
  '^(apply_patch|write|edit|modify|delete|create|move|rename)(_|$)' {'修改文件';break}
  '^(exec_command|write_stdin)$' {'执行命令';break}
  '^show_changes$' {'查看改动';break}
  default {'工具调用'}
 }
}
function Add-ToolActivityFromLine([string]$Line) {
 if([string]::IsNullOrWhiteSpace($Line)){return}
 try{$entry=$Line|ConvertFrom-Json -ErrorAction Stop}catch{return}
 if($entry.event -notin @("tool_call","artifact_tool_call")){return}
 $tool=[string]$entry.tool
 if($tool -notmatch "^[A-Za-z0-9_.-]{1,80}$"){return}
 $at=Get-Date
 if($entry.ts){try{$at=([DateTimeOffset]::Parse([string]$entry.ts)).ToLocalTime().DateTime}catch{}}
 $workspaceId="—";if(([string]$entry.workspaceId) -match "^ws_[A-Za-z0-9_-]{1,80}$"){$workspaceId=[string]$entry.workspaceId}
  $success=$null
  if($entry.PSObject.Properties["success"]){$success=[bool]$entry.success}
  $duration=$null
  if($entry.PSObject.Properties["durationMs"] -and $null -ne $entry.durationMs){try{$duration=[long]$entry.durationMs;if($duration -lt 0){$duration=$null}}catch{}}
  $item=[pscustomobject]@{At=$at;Action=(Get-ToolActionLabel $tool);Tool=$tool;WorkspaceId=$workspaceId;Success=$success;DurationMs=$duration}
 $index=0
 while($index -lt $script:ToolActivityEntries.Count -and $script:ToolActivityEntries[$index].At -ge $at){$index++}
  $script:ToolActivityEntries.Insert($index,$item)
  if($script:ToolActivityEntries.Count -gt 250){$script:ToolActivityEntries.RemoveAt(250)}
 $script:ToolActivityDirty=$true
}
function Refresh-ToolActivityList {
 if(!$script:ToolActivityDirty -or !$script:ToolCallList){return}
 $script:ToolCallList.BeginUpdate()
 try{
  $script:ToolCallList.Items.Clear()
  foreach($call in $script:ToolActivityEntries){
   $result=if($call.Success -eq $true){"成功"}elseif($call.Success -eq $false){"失败"}else{"未知"}
   $duration=if($null -eq $call.DurationMs){"—"}elseif($call.DurationMs -lt 1000){"$($call.DurationMs) ms"}else{("{0:N1} 秒" -f ($call.DurationMs/1000.0))}
   $listItem=[Windows.Forms.ListViewItem]::new($call.At.ToString("MM-dd HH:mm:ss"))
   [void]$listItem.SubItems.Add($call.Action);[void]$listItem.SubItems.Add($call.Tool);[void]$listItem.SubItems.Add($call.WorkspaceId);[void]$listItem.SubItems.Add($result);[void]$listItem.SubItems.Add($duration)
   if($call.Success -eq $false){$listItem.ForeColor=$script:Color.Red}elseif($call.Success -eq $true){$listItem.ForeColor=$script:Color.Text}else{$listItem.ForeColor=$script:Color.Yellow}
   [void]$script:ToolCallList.Items.Add($listItem)
  }
  $count=$script:ToolActivityEntries.Count
  $script:CallSummary.Text=if($count -gt 0){"最近 $count 次 · 只显示方法、工作区 ID、状态和耗时"}else{"暂无工具调用记录；真实调用发生后会自动显示。"}
 }finally{$script:ToolCallList.EndUpdate();$script:ToolActivityDirty=$false}
}
function Update-WorkspaceCacheList {
 if(!$script:WorkspaceCacheList){return}
 if(!$script:WorkspaceCacheReady){
  $script:WorkspaceCacheSummary.Text=if($script:WorkspaceCacheError){"缓存读取失败 · $($script:WorkspaceCacheError)"}else{"正在读取 active 持久会话…"}
  return
 }
 $entries=@($script:WorkspaceEntries);$existing=@($entries|Where-Object{$_.DirectoryExists}).Count;$missing=$entries.Count-$existing
 $script:WorkspaceCacheList.BeginUpdate()
 try{
  $script:WorkspaceCacheList.Items.Clear()
  foreach($entry in $entries){
   $root=[string]$entry.Root;$shownRoot=$root
   if($shownRoot.Length -gt 72){$shownRoot="…"+$shownRoot.Substring($shownRoot.Length-71)}
   $mode=if($entry.Mode -eq "worktree"){"worktree"}else{"checkout"}
   $directoryState=if($entry.DirectoryExists){"目录存在"}else{"目录缺失"}
   $lastUsed="—";try{$lastUsed=([DateTimeOffset]::Parse([string]$entry.LastUsedAt)).ToLocalTime().ToString("MM-dd HH:mm")}catch{}
   $row=[Windows.Forms.ListViewItem]::new([string]$entry.Id)
   [void]$row.SubItems.Add($shownRoot);[void]$row.SubItems.Add($mode);[void]$row.SubItems.Add($directoryState);[void]$row.SubItems.Add($lastUsed)
   $row.ToolTipText="工作目录：$root"+[Environment]::NewLine+"持久状态：active"+[Environment]::NewLine+"目录状态：$directoryState"
   if(!$entry.DirectoryExists){$row.ForeColor=$script:Color.Red}
   [void]$script:WorkspaceCacheList.Items.Add($row)
  }
  $updated=if($script:WorkspaceCacheUpdatedAt){$script:WorkspaceCacheUpdatedAt.ToString("HH:mm:ss")}else{"—"}
  $summary="active 持久会话 $($script:WorkspaceActiveCount) 条 · 最近候选 $($entries.Count)/32 · 目录存在 $existing / 缺失 $missing · 更新 $updated"
  if($script:WorkspaceCacheError){$summary="刷新失败，显示上次快照 · "+$summary}
  $script:WorkspaceCacheSummary.Text=$summary
 }finally{$script:WorkspaceCacheList.EndUpdate()}
}
function Start-WorkspaceCacheQuery {
 if($script:WorkspaceCacheAsync){return}
 $script:WorkspaceCacheNextRefresh=[DateTime]::Now.AddSeconds(10)
 try{
  $script:WorkspaceCachePS=[PowerShell]::Create();$script:WorkspaceCachePS.Runspace=$script:WorkspaceCacheRunspace
  [void]$script:WorkspaceCachePS.AddScript($script:WorkspaceCacheCode)
  foreach($argument in @($script:DevSpaceNode,$script:DevSpaceRepo,$script:DevSpaceStateDb)){[void]$script:WorkspaceCachePS.AddArgument($argument)}
  $script:WorkspaceCacheAsync=$script:WorkspaceCachePS.BeginInvoke()
 }catch{
  $message=Protect-Text $_.Exception.GetBaseException().Message;$script:WorkspaceCacheError=$message;$script:WorkspaceCacheNextRefresh=[DateTime]::Now.AddSeconds(30)
  Add-ManagerLog "ERROR" ("工作区缓存查询启动失败："+$message);Update-WorkspaceCacheList
  if($script:WorkspaceCachePS){$script:WorkspaceCachePS.Dispose()};$script:WorkspaceCachePS=$null;$script:WorkspaceCacheAsync=$null
 }
}
function Complete-WorkspaceCacheQuery {
 if(!$script:WorkspaceCacheAsync -or !$script:WorkspaceCacheAsync.IsCompleted){return}
 try{
  $resultItems=@($script:WorkspaceCachePS.EndInvoke($script:WorkspaceCacheAsync))
  $streamErrors=@($script:WorkspaceCachePS.Streams.Error)
  if($streamErrors.Count -gt 0){throw $streamErrors[-1].ToString()}
  if($resultItems.Count -eq 0 -or !$resultItems[-1]){throw "SQLite 查询没有返回数据。"}
  $result=$resultItems[-1]
  $firstLoad=!$script:WorkspaceCacheReady
  $script:WorkspaceActiveCount=[int]$result.activeCount
  $script:WorkspaceEntries=@(foreach($entry in @($result.entries)){
   [pscustomobject]@{Id=[string]$entry.id;Root=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$entry.rootBase64));Mode=[string]$entry.mode;LastUsedAt=[string]$entry.lastUsedAt;DirectoryExists=[bool]$entry.directoryExists}
  })
  $script:WorkspaceCacheError="";$script:WorkspaceCacheReady=$true;$script:WorkspaceCacheUpdatedAt=Get-Date
  if($firstLoad){Add-ManagerLog "INFO" ("工作区缓存已载入：active {0} 条，最近 {1} 条目录状态已检查。" -f $script:WorkspaceActiveCount,$script:WorkspaceEntries.Count)}
  Update-WorkspaceCacheList
 }catch{
  $message=Protect-Text $_.Exception.GetBaseException().Message
  if($script:WorkspaceCacheError -ne $message){Add-ManagerLog "ERROR" ("工作区缓存读取失败："+$message)}
  $script:WorkspaceCacheError=$message;$script:WorkspaceCacheNextRefresh=[DateTime]::Now.AddSeconds(30);Update-WorkspaceCacheList
 }finally{
  if($script:WorkspaceCachePS){$script:WorkspaceCachePS.Dispose()}
  $script:WorkspaceCachePS=$null;$script:WorkspaceCacheAsync=$null
 }
}
function Update-Dashboard($s) {
 if(!$s){return}
 $devOk=$s.DevTcp -and $s.DevOk -and $s.McpMeta
 $tunOk=$s.TunnelTcp -and $s.TunnelLive -and $s.TunnelReady -and $s.PollAge -ge 0 -and $s.PollAge -le 90 -and $s.Proxy -eq 1
 if($script:PreviousDevOk -and !$devOk -and !$script:OperationBusy){$script:DevCrashUntil=(Get-Date).AddSeconds(30);Add-ManagerLog 'ERROR' 'DevSpace 健康检查中断，服务可能异常退出。'}
 elseif(!$script:PreviousDevOk -and $devOk -and $script:DevCrashUntil -gt [DateTime]::MinValue -and !$script:OperationBusy){Add-ManagerLog 'INFO' 'DevSpace 已恢复健康。';$script:DevCrashUntil=[DateTime]::MinValue}
 if($script:PreviousTunnelOk -and !$tunOk -and !$script:OperationBusy){$script:TunnelCrashUntil=(Get-Date).AddSeconds(30);Add-ManagerLog 'ERROR' '隧道控制面轮询或代理健康检查中断。'}
 elseif(!$script:PreviousTunnelOk -and $tunOk -and $script:TunnelCrashUntil -gt [DateTime]::MinValue -and !$script:OperationBusy){Add-ManagerLog 'INFO' '隧道控制面轮询已恢复。';$script:TunnelCrashUntil=[DateTime]::MinValue}
 $script:PreviousDevOk=$devOk;$script:PreviousTunnelOk=$tunOk
 $pidText=if($s.DevPid -gt 0){"PID $($s.DevPid)"}else{'PID 未识别'};$uptime=Get-UptimeText $s.DevUptime
 if($s.DevCount -gt 1){Set-Card $script:DevCard '重复实例' "端口 7676 · $($s.DevCount) 个 Node" 'Red'}
 elseif($devOk){$tone=if($s.DevCount -eq 1){'Green'}else{'Yellow'};Set-Card $script:DevCard '运行中' "端口 7676 · $pidText · $uptime" $tone}
 elseif($s.DevCount -gt 0 -and $s.DevTcp){Set-Card $script:DevCard '启动中 / 检查失败' "Node PID $($s.DevPid) · HTTP 未通过" 'Yellow'}
 elseif($s.DevCount -gt 0){Set-Card $script:DevCard '异常' "PID $($s.DevPid) 存在，但端口未响应" 'Red'}
 elseif($s.DevTcp){Set-Card $script:DevCard '端口有响应' '进程归属无法确认，控制操作保持保守。' 'Yellow'}
 elseif($script:DevCrashUntil -gt (Get-Date)){Set-Card $script:DevCard '异常退出' '端口或 HTTP 健康检查失败。' 'Red'}
 else{Set-Card $script:DevCard '已停止' '端口 7676 无响应' 'Muted'}
 if($devOk -and $s.Protocol -eq 'oauth_required'){Set-Card $script:McpCard '端点可达' 'OAuth 元数据正常；MCP 要求授权，尚未验证授权调用。' 'Green'}
 elseif($devOk -and $s.Protocol -eq 'responded'){Set-Card $script:McpCard '需检查鉴权' '未授权请求得到有效 JSON-RPC result；请确认鉴权配置。' 'Yellow'}
 elseif($devOk -and $s.Protocol -eq 'stream_unverified'){Set-Card $script:McpCard '流式响应未验证' '收到 text/event-stream；未读取完整 initialize 事件。' 'Yellow'}
 elseif($devOk -and $s.Protocol -eq 'body_timeout'){Set-Card $script:McpCard '协议探测超时' 'HTTP 响应头已到达，但响应体未在时限内完成。' 'Red'}
 elseif($devOk -and $s.Protocol -eq 'not_checked'){Set-Card $script:McpCard '待验证' 'HTTP 与 OAuth 元数据正常；MCP 协议探测尚未执行。' 'Yellow'}
 elseif($devOk){Set-Card $script:McpCard '协议异常' "OAuth 元数据正常；initialize 探测结果：$($s.Protocol)" 'Red'}
 elseif($s.DevTcp -or $s.DevCount -gt 0){Set-Card $script:McpCard '不可用' '本机 MCP/OAuth 检查失败；点击一键诊断查看协议响应。' 'Yellow'}
 else{Set-Card $script:McpCard '不可用' 'DevSpace HTTP 服务未响应。' 'Red'}
 $tunPid=if($s.TunnelPid -gt 0){"PID $($s.TunnelPid)"}else{'PID 未识别'};$tunUptime=Get-UptimeText $s.TunnelUptime
 $poll=if($s.PollAge -ge 0){"控制面轮询 $($s.PollAge) 秒前"}else{'暂无成功轮询'}
 if($s.TunnelCount -gt 1){Set-Card $script:TunnelCard '重复实例' "$($s.TunnelCount) 个 HomePC profile 进程" 'Red'}
 elseif($tunOk){$tone=if($s.TunnelCount -eq 1){'Green'}else{'Yellow'};Set-Card $script:TunnelCard '已连接' "$poll · $tunPid · $tunUptime · proxy OK" $tone}
 elseif($s.TunnelCount -gt 0 -and $s.TunnelLive){Set-Card $script:TunnelCard '未确认连接' "进程存活；$poll · proxy $($s.Proxy)" 'Yellow'}
 elseif($s.TunnelCount -gt 0){Set-Card $script:TunnelCard '异常' "PID $($s.TunnelPid) 存在，但 health 未通过" 'Red'}
 elseif($s.TunnelTcp){Set-Card $script:TunnelCard '端口有响应' '进程归属不明，控制操作保持保守。' 'Yellow'}
 elseif($script:TunnelCrashUntil -gt (Get-Date)){Set-Card $script:TunnelCard '连接中断' $poll 'Red'}
 else{Set-Card $script:TunnelCard '未连接' '隧道客户端或控制面检查未通过。' 'Muted'}
 $tasks=if($s.TaskDev -and $s.TaskTunnel){'自启动已启用'}else{'自启动已暂停'}
 $script:Footer.Text="本机 7676 / 隧道 17676 · $tasks · 每 2 秒刷新 · 关闭窗口会缩到托盘"
}
function Start-HealthProbe([switch]$Full) {
 if($script:HealthAsync -and !$script:HealthAsync.IsCompleted){if($Full){$script:ForceProbe=$true;$script:ForceProtocol=$true};return}
 $now=Get-Date;$readHttp=$script:ForceProbe -or (($now-$script:LastHttpProbe).TotalSeconds -ge 12)
 $readTunnel=$script:ForceProbe -or (($now-$script:LastTunnelProbe).TotalSeconds -ge 5)
 $runProtocol=$Full -or $script:ForceProtocol -or $readHttp;$script:ForceProbe=$false;$script:ForceProtocol=$false
 $script:HealthPS=[PowerShell]::Create();$script:HealthPS.Runspace=$script:HealthRunspace;[void]$script:HealthPS.AddScript($script:ProbeCode)
 foreach($arg in @($script:DevSpaceBase,$script:TunnelBase,$script:DevSpaceNode,$script:DevSpaceCli,$script:TunnelExe,$script:TunnelProfileDir,[bool]$readHttp,[bool]$readTunnel,[bool]$runProtocol,[bool]$script:CachedDevOk,[bool]$script:CachedMcpMetaOk,[bool]$script:CachedTunnelLive,[bool]$script:CachedTunnelReady,[long]$script:CachedPollUnix,[int]$script:CachedProxy,[string]$script:CachedProtocol,[bool]$script:CachedChallenge)){[void]$script:HealthPS.AddArgument($arg)}
 $script:HealthAsync=$script:HealthPS.BeginInvoke()
}
function Complete-HealthProbe {
 if(!$script:HealthAsync -or !$script:HealthAsync.IsCompleted){return}
 try{
  $results=@($script:HealthPS.EndInvoke($script:HealthAsync))
  if($results.Count -gt 0){
   $s=$results[-1];$script:Snapshot=$s
   if($script:HealthPS.Streams.Error.Count -gt 0){Add-UiLog '诊断' (Protect-Text $script:HealthPS.Streams.Error[0].ToString()) 'WARN'}
   if($s.ReadHttp){$script:LastHttpProbe=Get-Date;$script:CachedDevOk=[bool]$s.DevOk;$script:CachedMcpMetaOk=[bool]$s.McpMeta}
   if($s.ReadTunnel){$script:LastTunnelProbe=Get-Date;$script:CachedTunnelLive=[bool]$s.TunnelLive;$script:CachedTunnelReady=[bool]$s.TunnelReady;$script:CachedPollUnix=[long]$s.PollLast;$script:CachedProxy=[int]$s.Proxy}
   $protocolChanged=$script:CachedProtocol -ne [string]$s.Protocol;$script:CachedProtocol=[string]$s.Protocol;$script:CachedChallenge=[bool]$s.Challenge;Update-Dashboard $s
   if($s.RunProtocol -and $protocolChanged){switch($s.Protocol){
    'oauth_required'{Add-ManagerLog 'INFO' 'MCP initialize 返回 OAuth 认证挑战（401）；端点在线并要求授权。'}
    'responded'{Add-ManagerLog 'WARN' '未授权 initialize 得到有效 JSON-RPC result；请检查鉴权设置。'}
'stream_unverified'{Add-ManagerLog 'WARN' 'MCP 返回 text/event-stream；未等待连接结束，initialize 事件未验证。'}
'body_timeout'{Add-ManagerLog 'ERROR' 'MCP 响应头已到达，但响应体超时，JSON-RPC 结果未验证。'}
    default{Add-ManagerLog 'ERROR' "MCP 协议探测失败：$($s.Protocol)"}
   }}
  }
 }catch{Add-ManagerLog 'ERROR' ("健康检查失败: "+$_.Exception.GetBaseException().Message)}
 finally{if($script:HealthPS){$script:HealthPS.Dispose()};$script:HealthPS=$null;$script:HealthAsync=$null}
}
function Set-ActionButtons([bool]$Enabled){$script:StartButton.Enabled=$Enabled;$script:StopButton.Enabled=$Enabled;$script:RestartButton.Enabled=$Enabled;$script:DiagnoseButton.Enabled=$Enabled;$script:OpenLogsButton.Enabled=$Enabled;$script:Form.UseWaitCursor=!$Enabled}
function Start-Action([string]$Action) {
 if($script:OperationBusy){Add-UiLog 'Manager' '已有服务操作正在运行。' 'WARN';return}
 if($Action -eq 'Start' -and $script:Snapshot -and ($script:Snapshot.DevCount -gt 1 -or $script:Snapshot.TunnelCount -gt 1)){Add-ManagerLog 'ERROR' '检测到重复进程；未启动新实例。';return}
 $script:OperationBusy=$true;Set-ActionButtons $false;Add-ManagerLog 'INFO' "执行操作: $Action"
 $script:ActionRunspace=[RunspaceFactory]::CreateRunspace();$script:ActionRunspace.ApartmentState='MTA';$script:ActionRunspace.ThreadOptions='ReuseThread';$script:ActionRunspace.Open()
 $script:ActionPS=[PowerShell]::Create();$script:ActionPS.Runspace=$script:ActionRunspace;[void]$script:ActionPS.AddScript($script:ActionCode)
 foreach($arg in @($Action,$script:HomeRoot,$script:DevSpaceNode,$script:DevSpaceCli,$script:TunnelExe,$script:TunnelProfileDir,$script:DevSpaceBase,$script:TunnelBase,$script:StartScript)){[void]$script:ActionPS.AddArgument($arg)}
 $script:ActionAsync=$script:ActionPS.BeginInvoke()
}
function Complete-Action {
 if(!$script:ActionAsync -or !$script:ActionAsync.IsCompleted){return}
 try{
  $items=@($script:ActionPS.EndInvoke($script:ActionAsync));$r=if($items.Count -gt 0){$items[-1]}else{$null};if(!$r){throw '操作没有返回结果。'}
  Add-ManagerLog ([string]$r.Severity) ([string]$r.Message)
  if(!$r.Success){[Windows.Forms.MessageBox]::Show((Protect-Text ([string]$r.Message)),'DevSpace Manager','OK','Error')|Out-Null}
 }catch{$m=Protect-Text $_.Exception.GetBaseException().Message;Add-ManagerLog 'ERROR' $m;[Windows.Forms.MessageBox]::Show($m,'DevSpace Manager','OK','Error')|Out-Null}
 finally{
  if($script:ActionPS){$script:ActionPS.Dispose()};if($script:ActionRunspace){$script:ActionRunspace.Close();$script:ActionRunspace.Dispose()}
  $script:ActionPS=$null;$script:ActionRunspace=$null;$script:ActionAsync=$null;$script:OperationBusy=$false;Set-ActionButtons $true;$script:ForceProbe=$true
 }
}
function Show-FullLog {
 $source=$script:LogCombo.SelectedItem
 if(!$source -or !(Test-Path -LiteralPath $source.Path)){Add-ManagerLog 'WARN' '所选日志不存在。';return}
 $viewer=$null;$stream=$null;$reader=$null
 try{
  $viewer=[Windows.Forms.Form]::new();$viewer.Text="DevSpace Manager · $($source.Name)（敏感字段已遮盖）";$viewer.StartPosition='CenterParent';$viewer.Size=[Drawing.Size]::new(950,650);$viewer.BackColor=$script:Color.Back
  $box=[Windows.Forms.RichTextBox]::new();$box.Dock='Fill';$box.ReadOnly=$true;$box.DetectUrls=$false;$box.WordWrap=$false;$box.BackColor=$script:Color.Log;$box.ForeColor=$script:Color.Text;$box.Font=[Drawing.Font]::new('Consolas',9);$box.MaxLength=[int]::MaxValue
  $stream=[IO.File]::Open($source.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
  $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true);$buffer=[Text.StringBuilder]::new();$pendingSensitive=$false
  $pendingPattern='(?i)(?:["'']?\b[A-Za-z0-9_-]*(?:token|secret|key|password|authorization)\b["'']?)\s*[:=]\s*$'
  while(($rawLine=$reader.ReadLine()) -ne $null){
   $line=$rawLine
   if($pendingSensitive -and [string]::IsNullOrWhiteSpace($line)){$line=$rawLine}
   elseif($pendingSensitive){
    $indent=[regex]::Match($line,'^\s*').Value;$comma=if($line -match ',\s*$'){','}else{''}
    $line=$indent+'"<redacted>"'+$comma;$pendingSensitive=$false
   }elseif($line -match $pendingPattern){$pendingSensitive=$true}
   $line=Protect-Text $line
   [void]$buffer.AppendLine($line)
   if($buffer.Length -ge 16384){[void]$box.AppendText($buffer.ToString());[void]$buffer.Clear()}
  }
  if($buffer.Length -gt 0){[void]$box.AppendText($buffer.ToString())}
  $viewer.Controls.Add($box);[void]$viewer.ShowDialog($script:Form)
 }catch{
  $m=Protect-Text $_.Exception.GetBaseException().Message;Add-ManagerLog 'ERROR' ("完整日志读取失败: "+$m)
  [Windows.Forms.MessageBox]::Show($m,'DevSpace Manager','OK','Error')|Out-Null
 }finally{
  if($reader){$reader.Dispose()};if($stream){$stream.Dispose()};if($viewer){$viewer.Dispose()}
 }
}
function Load-InitialLogs {
 $pendingPattern='(?i)(?:["'']?\b[A-Za-z0-9_-]*(?:token|secret|key|password|authorization)\b["'']?)\s*[:=]\s*$'
 foreach($source in $script:LogSources){if(!(Test-Path -LiteralPath $source.Path)){continue}
  $stream=$null;$reader=$null
  try{
   $stream=[IO.File]::Open($source.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
   $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true);$activityLines=[Collections.Generic.List[string]]::new();$recent=[Collections.Generic.Queue[string]]::new();$pending=$false;$pendingAtLastLine=$false;$lastRawLine=$null
   while(($line=$reader.ReadLine()) -ne $null){
    $pendingAtLastLine=$pending;$lastRawLine=$line
     if($source.ToolActivity){
     try{
      $activityEntry=$line|ConvertFrom-Json -ErrorAction Stop
      if($activityEntry.event -in @("tool_call","artifact_tool_call")){
       if($activityLines.Count -ge 250){$activityLines.RemoveAt(0)}
       $activityLines.Add([string]$line)
      }
     }catch{}
    }
    if($pending -and [string]::IsNullOrWhiteSpace($line)){}
    elseif($pending){
     $indent=[regex]::Match($line,'^\s*').Value;$comma=if($line -match ',\s*$'){','}else{''}
     $line=$indent+'"<redacted>"'+$comma;$pending=$false
    }elseif($line -match $pendingPattern){$pending=$true}
    $line=Protect-Text $line
    if($recent.Count -eq 8){[void]$recent.Dequeue()}
    $recent.Enqueue($line)
   }
   $scanEnd=[long]$stream.Position;$terminated=$true
   if($scanEnd -gt 0){[void]$stream.Seek($scanEnd-1,[IO.SeekOrigin]::Begin);$lastByte=$stream.ReadByte();$terminated=($lastByte -eq 10 -or $lastByte -eq 13)}
    if($source.ToolActivity -and !$terminated -and $activityLines.Count -gt 0 -and $activityLines[$activityLines.Count-1] -ceq $lastRawLine){$activityLines.RemoveAt($activityLines.Count-1)}
   $recentLines=@($recent);$displayCount=$recentLines.Count;$pendingForNext=$pending
   if(!$terminated -and $displayCount -gt 0){$displayCount--;$script:LogBuffers[$source.Path]=[string]$lastRawLine;$pendingForNext=$pendingAtLastLine}
   else{$script:LogBuffers[$source.Path]=''}
   for($i=0;$i -lt $displayCount;$i++){Add-UiLog $source.Name $recentLines[$i] $source.Severity}
    if($source.ToolActivity){foreach($activityLine in $activityLines){Add-ToolActivityFromLine $activityLine}}
   $script:PendingLogValues[$source.Name]=$pendingForNext;$script:LogOffsets[$source.Path]=$scanEnd
  }catch{Add-UiLog 'Manager' ("启动日志载入失败: "+$_.Exception.GetBaseException().Message) 'WARN'}
  finally{if($reader){$reader.Dispose()};if($stream){$stream.Dispose()}}
 }
}
function Read-NewLogLines {
 foreach($source in $script:LogSources){$path=$source.Path;if(!(Test-Path -LiteralPath $path)){continue}
  try{
   $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
   if(!$script:LogOffsets.ContainsKey($path)){$script:LogOffsets[$path]=0}
   if($stream.Length -lt [long]$script:LogOffsets[$path]){$script:LogOffsets[$path]=0;$script:LogBuffers[$path]=''}
   if($stream.Length -le [long]$script:LogOffsets[$path]){$stream.Dispose();continue}
   [void]$stream.Seek([long]$script:LogOffsets[$path],[IO.SeekOrigin]::Begin);$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
   $chunk=$reader.ReadToEnd();$script:LogOffsets[$path]=$stream.Position;$reader.Dispose();$stream.Dispose()
   $combo=[string]$script:LogBuffers[$path]+$chunk;$parts=[regex]::Split($combo,'\r?\n');$ended=$combo.EndsWith([string][char]10)-or $combo.EndsWith([string][char]13)
   if(!$ended -and $parts.Count -gt 0){$script:LogBuffers[$path]=$parts[-1];if($parts.Count -gt 1){$parts=$parts[0..($parts.Count-2)]}else{$parts=@()}}else{$script:LogBuffers[$path]=''}
    foreach($line in $parts){if($source.ToolActivity){Add-ToolActivityFromLine $line};Add-UiLog $source.Name $line $source.Severity}
  }catch{}
 }
 Refresh-ToolActivityList
}

$script:StartButton.Add_Click({Start-Action 'Start'});$script:StopButton.Add_Click({Start-Action 'Stop'});$script:RestartButton.Add_Click({Start-Action 'Restart'})
$script:DiagnoseButton.Add_Click({Add-ManagerLog 'INFO' '运行 DevSpace、MCP OAuth 和隧道健康诊断。';$script:ForceProbe=$true;$script:ForceProtocol=$true;Start-HealthProbe -Full})
$script:OpenLogsButton.Add_Click({Show-FullLog});$script:FullLogButton.Add_Click({Show-FullLog})
$script:CopyButton.Add_Click({try{if($script:LogBox.TextLength -gt 0){[Windows.Forms.Clipboard]::SetText($script:LogBox.Text)};Add-ManagerLog 'INFO' '已复制当前实时日志。'}catch{Add-ManagerLog 'WARN' '复制失败。'}})
$script:ClearButton.Add_Click({$script:LogBox.Clear()})

$script:Notify=[Windows.Forms.NotifyIcon]::new();$script:Notify.Icon=[Drawing.SystemIcons]::Application;$script:Notify.Text='DevSpace Manager'
$menu=[Windows.Forms.ContextMenuStrip]::new();$openItem=[Windows.Forms.ToolStripMenuItem]::new('打开 DevSpace Manager')
$startItem=[Windows.Forms.ToolStripMenuItem]::new('启动服务');$restartItem=[Windows.Forms.ToolStripMenuItem]::new('重启服务');$exitItem=[Windows.Forms.ToolStripMenuItem]::new('退出管理器')
[void]$menu.Items.Add($openItem);[void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new());[void]$menu.Items.Add($startItem);[void]$menu.Items.Add($restartItem);[void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new());[void]$menu.Items.Add($exitItem)
$script:Notify.ContextMenuStrip=$menu;$script:Timer=[Windows.Forms.Timer]::new();$script:Timer.Interval=2000
$openItem.Add_Click({$script:Notify.Visible=$false;$script:Form.Show();$script:Form.WindowState='Normal';$script:Form.Activate()})
$startItem.Add_Click({Start-Action 'Start'});$restartItem.Add_Click({Start-Action 'Restart'})
$exitItem.Add_Click({if($script:OperationBusy){Add-ManagerLog 'WARN' '服务操作尚未完成；请等待操作结束后再退出管理器。';return};$script:AllowExit=$true;$script:Timer.Stop();$script:Notify.Visible=$false;$script:Form.Close()})
$script:Notify.Add_DoubleClick({$script:Notify.Visible=$false;$script:Form.Show();$script:Form.WindowState='Normal';$script:Form.Activate()})
$script:Form.Add_Resize({if($script:Form.WindowState -eq 'Minimized'){$script:Form.Hide();$script:Notify.Visible=$true;$script:Notify.BalloonTipTitle='DevSpace Manager';$script:Notify.BalloonTipText='服务继续在后台运行。';$script:Notify.ShowBalloonTip(1200)}})
$script:Form.Add_FormClosing({param($sender,$e)if(!$script:AllowExit){$e.Cancel=$true;$script:Form.Hide();$script:Notify.Visible=$true}else{$script:Notify.Visible=$false}})
$script:Timer.Add_Tick({Complete-HealthProbe;Complete-Action;Complete-WorkspaceCacheQuery;Read-NewLogLines;Refresh-ToolActivityList;if(!$script:WorkspaceCacheAsync -and (Get-Date) -ge $script:WorkspaceCacheNextRefresh){Start-WorkspaceCacheQuery};if(!$script:HealthAsync){Start-HealthProbe}})
Load-InitialLogs
Add-ManagerLog 'INFO' 'DevSpace Manager 已启动；关闭窗口只隐藏管理器，不会停止服务。'
$script:Timer.Start();Start-HealthProbe;Start-WorkspaceCacheQuery
$script:Form.Add_Shown({
    $consoleWindow = [DevSpaceManagerNative]::GetConsoleWindow()
    if ($consoleWindow -ne [IntPtr]::Zero) { [void][DevSpaceManagerNative]::ShowWindow($consoleWindow, 0) }
    [void][DevSpaceManagerNative]::ShowWindow($script:Form.Handle, 5)
    [void][DevSpaceManagerNative]::SetForegroundWindow($script:Form.Handle)
})
function Stop-ManagerResources {
 try{$script:Timer.Stop()}catch{}
 try{$script:Notify.Visible=$false}catch{}
 foreach($pipeline in @($script:HealthPS,$script:ActionPS,$script:WorkspaceCachePS)){
  if($pipeline){try{$pipeline.Stop()}catch{};try{$pipeline.Dispose()}catch{}}
 }
 foreach($runspace in @($script:HealthRunspace,$script:ActionRunspace,$script:WorkspaceCacheRunspace)){
  if($runspace){try{$runspace.Close()}catch{};try{$runspace.Dispose()}catch{}}
 }
 try{$script:Timer.Dispose()}catch{}
 try{$script:Notify.Dispose()}catch{}
}
try{[void][Windows.Forms.Application]::Run($script:Form)}finally{Stop-ManagerResources}
