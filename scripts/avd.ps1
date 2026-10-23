<#
  AVD manager for the AVD Mirror skill.

  Owns everything about the *emulator process* - which AVDs exist, which one is
  running, starting one, stopping one - while mirror.ps1 owns the *capture and
  input* of a running one. Keeping this separate means the controls work whether
  or not a mirror server is up, and mirror.ps1 never has to know how to launch
  an emulator.

  Runs as a small HTTP server on 8779 with CORS (the mirror page calls it
  cross-origin, exactly as it already does for wgccap on 8778), and doubles as a
  one-shot CLI:

      avd.ps1 -Command list
      avd.ps1 -Command status
      avd.ps1 -Command start -Name ai_dating
      avd.ps1 -Command stop -Force

  HTTP:
      GET  /health          -> "ok"
      GET  /avds            -> JSON: list, running, selected, busy
      POST /avd/start?name= -> starts, returns immediately (poll /avds)
      POST /avd/stop?force= -> stops, returns immediately (poll /avds)

  Start and stop deliberately return before the emulator has finished. The
  accept loop is single-threaded, so a request that blocked for the ~40 s an AVD
  takes to boot would stall every other request behind it - the same trap that
  made /input?swipe have to be replayed in the page instead of on the server.
  State is read back from the system on every poll rather than tracked, so an
  AVD started or killed outside this script is reflected automatically.
#>

param(
  [int]$Port = 8779,
  [ValidateSet('list', 'status', 'start', 'stop', 'selected', 'serve')]
  [string]$Command = 'serve',
  [string]$Name,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- locate the Android SDK -------------------------------------------------
$sdkRoot = $env:LOCALAPPDATA
if (-not (Test-Path (Join-Path $sdkRoot 'Android\Sdk'))) { $sdkRoot = $env:ANDROID_HOME }
if (-not (Test-Path (Join-Path $sdkRoot 'Android\Sdk'))) { $sdkRoot = 'C:\Android\Sdk' }

$emulatorExe = Join-Path $sdkRoot 'Android\Sdk\emulator\emulator.exe'
if (-not (Test-Path $emulatorExe)) { $emulatorExe = (Get-Command emulator -ErrorAction SilentlyContinue).Source }

$adbExe = Join-Path $sdkRoot 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adbExe)) { $adbExe = (Get-Command adb -ErrorAction SilentlyContinue).Source }
if (-not $adbExe) { throw 'adb.exe not found - install platform-tools.' }

# --- AVD home ---------------------------------------------------------------
# ANDROID_AVD_HOME wins when set (this machine uses E:\Android\avd), otherwise
# the SDK default. Resolved once: it does not change while the script runs.
function Get-AvdHome {
  if ($env:ANDROID_AVD_HOME -and (Test-Path $env:ANDROID_AVD_HOME)) { return $env:ANDROID_AVD_HOME }
  $p = Join-Path $env:USERPROFILE '.android\avd'
  if (Test-Path $p) { return $p }
  return $null
}

# The AVD the user last picked, so a restart can come back up where it left off.
function Get-SelectedPath { Join-Path $env:LOCALAPPDATA 'avd-mirror-selected.txt' }
function Get-Selected {
  # -Raw reads the file as one string and [string] forces the type. Without
  # both, the value came back as a provider-decorated PSObject inside the
  # server (it is a plain string in an interactive shell), and that object
  # serialised into the /avds JSON as a nested blob instead of the AVD name.
  try { return ([string](Get-Content (Get-SelectedPath) -Raw -ErrorAction Stop)).Trim() } catch { return '' }
}
function Set-Selected {
  param([string]$Value)
  try {
    $dir = Split-Path (Get-SelectedPath) -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path (Get-SelectedPath) -Value $Value -Encoding utf8 -NoNewline
  } catch { }
}

# --- adb --------------------------------------------------------------------
# adb and emulator.exe write routine chatter to stderr ("* daemon not running;
# starting now at tcp:5037", "INFO | ...", "error: no devices/emulators found").
# Under $ErrorActionPreference = 'Stop', a native command's stderr captured with
# 2>&1 becomes a *terminating* NativeCommandError, so the first such line threw:
# the request handler's catch swallowed it and closed the connection with no
# reply at all, which blanked the AVDs tree. Run every external tool through
# this and its stderr is just text.
function Invoke-Native {
  param([scriptblock]$Command)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command 2>&1 | ForEach-Object { [string]$_ } }
  finally { $ErrorActionPreference = $prev }
}

function Invoke-Adb {
  param([string[]]$Arguments)
  Invoke-Native { & $adbExe @Arguments }
}

# --- inventory --------------------------------------------------------------
# `emulator -list-avds` is the reliable enumerator here. `avdmanager list avd`
# reports this machine's AVD as "Corrupted AVD ini file" even though the emulator
# boots it fine, so it is not used - it would hide every AVD on this setup.
$script:AvdListCache = $null
$script:AvdListAt = [datetime]::MinValue

function Get-AvdNames {
  if ($script:AvdListCache -and ([datetime]::UtcNow - $script:AvdListAt).TotalSeconds -lt 10) {
    return $script:AvdListCache
  }
  $names = @()
  if (Test-Path $emulatorExe) {
    foreach ($line in (Invoke-Native { & $emulatorExe '-list-avds' })) {
      $t = ($line -as [string]).Trim()
      if ($t) { $names += $t }
    }
  }
  $script:AvdListCache = $names
  $script:AvdListAt = [datetime]::UtcNow
  return $names
}

# Details come from the AVD's own config.ini, which is plain key=value.
function Get-AvdConfig {
  param([string]$AvdName)
  # Not $home: PowerShell's $HOME is read-only and variable names are
  # case-insensitive, so assigning to $home throws.
  $avdHome = Get-AvdHome
  if (-not $avdHome) { return @{} }
  $path = Join-Path $avdHome "$AvdName.avd\config.ini"
  if (-not (Test-Path $path)) { return @{} }
  $cfg = @{}
  foreach ($line in (Get-Content $path)) {
    # [string] for the same reason as Get-Selected: a decorated PSObject would
    # serialise as a nested blob rather than as the config value.
    if (([string]$line) -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') { $cfg[[string]$Matches[1]] = [string]$Matches[2] }
  }
  return $cfg
}

function Get-AvdSummary {
  param([string]$AvdName)
  $cfg = Get-AvdConfig -AvdName $AvdName
  # The API level is not a key of its own here - it is embedded in the system
  # image path, e.g. image.sysdir.1 = system-images\android-34\...\x86_64\.
  # The ini on this machine has no `target` key at all, so reading it would show
  # a blank API for every AVD.
  $sysdir = if ($cfg['image.sysdir.1']) { $cfg['image.sysdir.1'] } else { '' }
  $apiNum = ''
  if ($sysdir -match 'android-(\d+)') { $apiNum = $Matches[1] }
  elseif ($cfg['target'] -match '(\d+)') { $apiNum = $Matches[1] }
  $api = if ($apiNum) { "API $apiNum" } else { '' }
  $abi = if ($cfg['abi.type']) { $cfg['abi.type'] } else { '' }
  # The device the AVD was created as, e.g. pixel_4 - useful in a selector where
  # several AVDs differ only by name.
  $device = if ($cfg['hw.device.name']) { $cfg['hw.device.name'] } else { '' }
  return [ordered]@{
    name   = $AvdName
    api    = $api
    abi    = $abi
    device = $device
  }
}

# --- running state ----------------------------------------------------------
# Which emulator is up, and which AVD it is. Reads the system, never a cached
# flag, so a kill from a terminal or a crash is picked up on the next poll.
function Get-RunningAvd {
  $serials = @()
  foreach ($line in (Invoke-Adb -Arguments @('devices'))) {
    if ($line -match '^\s*(emulator-\d+)\s+device') { $serials += $Matches[1] }
  }
  foreach ($s in $serials) {
    $name = ''
    try {
      $out = (Invoke-Adb -Arguments @('-s', $s, 'emu', 'avd', 'name') | Out-String)
      $m = [regex]::Match($out, '(?m)^([A-Za-z0-9_.\-]+)\s*$')
      if ($m.Success) { $name = $m.Groups[1].Value }
    } catch { }
    if ($name -and $name -ne 'OK') {
      return [ordered]@{ name = $name; serial = $s; port = [int]($s -replace 'emulator-', '') }
    }
  }
  return $null
}

# sys.boot_completed flips to 1 once the guest is usable. Distinct from the
# process merely existing, which happens long before input works.
function Test-AvdBooted {
  param([string]$Serial)
  try {
    $out = (Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'getprop', 'sys.boot_completed') | Out-String)
    return ($out.Trim() -eq '1')
  } catch { return $false }
}

function Get-State {
  $running = Get-RunningAvd
  $busy = $false
  $status = 'stopped'
  $serial = ''
  if ($running) {
    $serial = $running.serial
    if (Test-AvdBooted -Serial $serial) { $status = 'running' }
    else { $status = 'starting'; $busy = $true }
  }
  else {
    # adb is not always the first thing up: for the first stretch of a boot the
    # emulator process exists but `adb devices` has not registered it, and
    # `adb emu avd name` has nothing to answer on. Reading adb alone made the
    # status read "stopped" for ~10s while the AVD was plainly starting, so the
    # qemu process is used as the fallback signal.
    $qemu = @(Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue)
    if ($qemu.Count -gt 0) { $status = 'starting'; $busy = $true }
  }
  return [ordered]@{
    status    = $status
    name      = if ($running) { $running.name } else { '' }
    serial    = $serial
    port      = if ($running) { $running.port } else { 0 }
    selected  = Get-Selected
    busy      = $busy
  }
}

function Get-AvdsJson {
  $st = Get-State
  $list = @()
  foreach ($n in (Get-AvdNames)) {
    $s = Get-AvdSummary -AvdName $n
    $list += [ordered]@{
      name    = $s.name
      api     = $s.api
      abi     = $s.abi
      device  = $s.device
      running = ($st.name -eq $n -and $st.status -eq 'running')
      current = ($st.name -eq $n)
    }
  }
  $payload = [ordered]@{
    status   = $st.status
    running  = $st.name
    serial   = $st.serial
    port     = $st.port
    selected = $st.selected
    busy     = $st.busy
    avds     = $list
  }
  return ($payload | ConvertTo-Json -Depth 5 -Compress)
}

# --- start / stop -----------------------------------------------------------
# The launch line mirrors how this AVD is started elsewhere (see
# emu-launch-params.txt in the AVD dir): -dns-server is what the existing setup
# uses, so a start from here behaves like a start by hand.
function Start-Avd {
  param([string]$AvdName)

  if (-not $AvdName) { return @{ ok = $false; error = 'no AVD name given' } }
  $names = Get-AvdNames
  if ($names -notcontains $AvdName) { return @{ ok = $false; error = "unknown AVD '$AvdName'" } }

  $st = Get-State
  if ($st.status -eq 'running' -or $st.status -eq 'starting') {
    if ($st.name -eq $AvdName) { return @{ ok = $true; error = ''; already = $true } }
    return @{ ok = $false; error = "'$($st.name)' is already running - stop it first" }
  }
  if (-not (Test-Path $emulatorExe)) { return @{ ok = $false; error = 'emulator.exe not found' } }

  $args = @('-avd', $AvdName, '-dns-server', '8.8.8.8,1.1.1.1')
  # The console window is hidden but the emulator still opens its own GUI window,
  # which mirror.ps1 needs (it requires a MainWindowHandle).
  Start-Process -FilePath $emulatorExe -ArgumentList $args -WindowStyle Hidden | Out-Null
  Set-Selected -Value $AvdName
  # Forget the cached inventory so a newly created AVD shows up immediately.
  $script:AvdListCache = $null
  return @{ ok = $true; error = '' }
}

function Stop-Avd {
  param([switch]$Force)

  $st = Get-State
  $running = Get-RunningAvd
  if (-not $running) { return @{ ok = $true; error = ''; already = $true } }

  if ($Force) {
    # Immediate. Loses unsaved guest state, which is the point of asking.
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | ForEach-Object {
      try { $_.Kill(); [void]$_.WaitForExit(5000) } catch { }
    }
    return @{ ok = $true; error = '' }
  }

  # Graceful: ask the emulator to shut itself down and wait for it to go.
  [void](Invoke-Adb -Arguments @('-s', $running.serial, 'emu', 'kill'))
  $deadline = [datetime]::UtcNow.AddSeconds(20)
  while ([datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if (-not (Get-RunningAvd)) { return @{ ok = $true; error = '' } }
  }
  return @{ ok = $false; error = 'emulator did not exit within 20s - use force' }
}

# --- CLI --------------------------------------------------------------------
function Invoke-Cli {
  switch ($Command) {
    'list' {
      $st = Get-State
      foreach ($n in (Get-AvdNames)) {
        $s = Get-AvdSummary -AvdName $n
        $mark = if ($st.name -eq $n) { '[running]' } elseif ($n -eq $st.selected) { '[selected]' } else { '' }
        Write-Output ("{0,-24} {1,-8} {2,-16} {3}" -f $n, $s.api, $s.abi, $mark)
      }
      if (-not (Get-AvdNames)) { Write-Output '(no AVDs found)' }
    }
    'status' {
      $st = Get-State
      Write-Output ("status={0} name={1} serial={2} selected={3}" -f $st.status, $st.name, $st.serial, $st.selected)
    }
    'selected' {
      Write-Output (Get-Selected)
    }
    'start' {
      $r = Start-Avd -AvdName $Name
      if (-not $r.ok) { Write-Output "error: $($r.error)"; exit 1 }
      if ($r.already) { Write-Output "already running: $Name"; exit 0 }
      Write-Output "starting: $Name"
    }
    'stop' {
      $r = Stop-Avd -Force:$Force
      if (-not $r.ok) { Write-Output "error: $($r.error)"; exit 1 }
      if ($r.already) { Write-Output 'nothing running'; exit 0 }
      Write-Output 'stopping'
    }
  }
}

if ($Command -ne 'serve') { Invoke-Cli; exit 0 }

# --- HTTP server ------------------------------------------------------------
function Send-Bytes([System.Net.Sockets.NetworkStream]$s, [string]$status, [string]$contentType, [byte[]]$body) {
  # CORS is required: the mirror page is served from 8777 and calls this origin
  # cross-origin, and the VS Code webview's origin is not 127.0.0.1 at all.
  # Bound to loopback only, so the exposure is other local processes - never the
  # network.
  $head = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nConnection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $s.Write($hb, 0, $hb.Length)
  if ($body -and $body.Length -gt 0) { $s.Write($body, 0, $body.Length) }
  $s.Flush()
}

function Get-QueryParams {
  param([string]$Path)
  $p = @{}
  $qi = $Path.IndexOf('?')
  if ($qi -lt 0) { return $p }
  foreach ($kv in ($Path.Substring($qi + 1) -split '&')) {
    if (-not $kv) { continue }
    $i = $kv.IndexOf('=')
    if ($i -gt 0) {
      $p[[uri]::UnescapeDataString($kv.Substring(0, $i))] = [uri]::UnescapeDataString($kv.Substring($i + 1))
    }
  }
  return $p
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Output "AVD manager listening on http://127.0.0.1:$Port/"

while ($true) {
  $tcp = $listener.AcceptTcpClient()
  try {
    $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $buf = New-Object byte[] 8192
    $acc = ''; $total = 0
    while (-not $acc.Contains("`r`n`r`n") -and $total -lt 8192) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $acc += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n); $total += $n
    }
    $requestLine = ($acc -split "`r`n")[0]
    $parts = $requestLine -split ' '
    $method = if ($parts.Count -gt 0) { $parts[0] } else { 'GET' }
    $path = if ($parts.Count -gt 1) { $parts[1] } else { '/' }
    if (-not $path) { $path = '/' }
    $q = Get-QueryParams -Path $path

    if ($method -eq 'OPTIONS') {
      Send-Bytes $stream '204 No Content' 'text/plain' ([byte[]]@())
    }
    elseif ($path -like '/health*') {
      Send-Bytes $stream '200 OK' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes('ok'))
    }
    elseif ($path -like '/avds*') {
      Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes((Get-AvdsJson)))
    }
    elseif ($path -like '/avd/start*') {
      $r = Start-Avd -AvdName ($q['name'])
      $body = ($r | ConvertTo-Json -Compress)
      if ($r.ok) { Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body)) }
      else      { Send-Bytes $stream '409 Conflict' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body)) }
    }
    elseif ($path -like '/avd/stop*') {
      $r = Stop-Avd -Force:([bool]$q['force'])
      $body = ($r | ConvertTo-Json -Compress)
      if ($r.ok) { Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body)) }
      else      { Send-Bytes $stream '409 Conflict' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body)) }
    }
    elseif ($path -like '/avd/select*') {
      if ($q['name']) { Set-Selected -Value $q['name'] }
      Send-Bytes $stream '200 OK' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes((Get-Selected)))
    }
    else {
      Send-Bytes $stream '404 Not Found' 'text/plain' ([byte[]][char[]]'not found')
    }
  }
  catch { }
  finally { $tcp.Close() }
}
