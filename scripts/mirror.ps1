<#
.SYNOPSIS
  Mirrors the Android emulator window inside VS Code (or any browser),
  independent of the emulator window's z-order / visibility.

.DESCRIPTION
  Tinder (and other apps) set FLAG_SECURE, which blacks out every in-guest
  capture path (screencap / screenrecord / scrcpy). This instead captures the
  emulator *host window* from Windows with PrintWindow(PW_RENDERFULLCONTENT),
  which works even when the emulator is fully occluded.

  Minimized windows cannot be captured (DWM has no surface), so when the
  emulator is minimized the script auto-restores it and parks it just outside
  the virtual screen (invisible, still rendering), then drops its taskbar button
  and Alt-Tab entry so nothing of it is left in the shell. GET /window?hidden=1
  does the same on demand; showing it puts all three back.

  Serves:
    GET /            -> HTML mirror page (auto-polling JPEG view)
    GET /frame.jpg   -> one JPEG frame of the emulator window

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File mirror.ps1 -Port 8777 -Quality 70

.NOTES
  Stop: stop this process, or: Stop-Process -Id <pid>
#>
param(
  [int]$Port = 8777,
  [int]$Quality = 70,          # JPEG quality 1-100
  [switch]$NoRescue,           # do not auto-restore/park a minimized emulator
  [string]$Avd = '',           # AVD to start if none is running (default: the selected one)
  [switch]$NoAutoStart,        # fail instead of starting an AVD when none is running
  # Where the AVD manager (avd.ps1) ended up. It prefers 8779 but moves when that
  # port is taken, and the page has to call the same one - see the rewrite below.
  [int]$AvdPort = 8779
)

$ErrorActionPreference = 'Stop'

# Identify the exact script this process loaded, so the extension can tell a
# server left over from an older build apart from the one it ships. Without this
# a stale server keeps serving last build's page, capture and window code while
# the extension's new menu sits on top of it - silent, because /gsize says "up"
# either way.
$script:BuildId = ''
try {
  $script:BuildId = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.Substring(0, 12).ToLowerInvariant()
} catch { }

# --- locate the emulator window ---------------------------------------------
# The AVD the user picked in the extension's AVD list, shared with avd.ps1. Kept
# as a plain file so both scripts agree on it without a shared process.
$SelectedAvdFile = Join-Path $env:LOCALAPPDATA 'avd-mirror-selected.txt'

function Get-SelectedAvd {
  try { return (Get-Content $SelectedAvdFile -ErrorAction Stop | Select-Object -First 1).Trim() } catch { return '' }
}

# adb writes routine chatter to stderr ("* daemon not running; starting now at
# tcp:5037", "error: no devices/emulators found"). Under $ErrorActionPreference =
# 'Stop', a native command's stderr captured with 2>&1 becomes a *terminating*
# NativeCommandError, so the first such line threw and that reply (guest size, a
# nav key, a tap) was lost. Run every external tool through this and its stderr
# is just text.
#
# Defined here, above its first caller: Start-AvdAndWait() runs at startup, when
# no emulator is running, and a function is only callable once the script has
# reached its definition. With this further down, the cold start died on
# "Invoke-Native is not recognized" before the AVD it was there to start.
function Invoke-Native {
  param([scriptblock]$Command)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command 2>&1 | ForEach-Object { [string]$_ } }
  finally { $ErrorActionPreference = $prev }
}

# Start an AVD and wait for its window. The wait is generous: a cold AVD boot on
# this machine measures ~38 s to sys.boot_completed, and the window handle the
# capture needs appears a little before that.
function Start-AvdAndWait {
  param([string]$AvdName, [int]$TimeoutSec = 180)

  $avdScript = Join-Path $PSScriptRoot 'avd.ps1'
  if (-not (Test-Path $avdScript)) {
    throw "AVD '$AvdName' cannot be started: avd.ps1 not found next to mirror.ps1."
  }
  # Write-Host, not Write-Output: everything a function writes to the output
  # stream becomes part of its return value, so the progress lines would have
  # turned the returned process into an array and $qemu.MainWindowHandle would
  # no longer be a handle. Write-Host goes to the host and leaves the pipeline
  # clean.
  Write-Host "no emulator running - starting AVD '$AvdName'"
  $out = Invoke-Native { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $avdScript -Command start -Name $AvdName }
  foreach ($line in $out) { Write-Host "  avd.ps1: $line" }

  $began = [datetime]::UtcNow
  $deadline = $began.AddSeconds($TimeoutSec)
  while ([datetime]::UtcNow -lt $deadline) {
    $q = Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($q) {
      Write-Host "  AVD '$AvdName' window up after $([int]([datetime]::UtcNow - $began).TotalSeconds)s"
      return $q
    }
    Start-Sleep -Milliseconds 750
  }
  throw "AVD '$AvdName' did not open a window within $TimeoutSec s."
}

$qemu = Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1

if (-not $qemu) {
  # Nothing running: start the selected AVD (or the one named on the command
  # line) rather than failing, so the mirror comes up on its own.
  $want = if ($Avd) { $Avd } else { Get-SelectedAvd }
  if ($NoAutoStart) {
    throw 'No running Android emulator window (qemu-system-x86_64) found.'
  }
  if (-not $want) {
    throw 'No running Android emulator, and no AVD is selected. Pick one in the AVD Mirror panel, or pass -Avd <name>.'
  }
  $qemu = Start-AvdAndWait -AvdName $want
}
$hwnd = $qemu.MainWindowHandle

# The emulator window and its console port are re-acquired rather than fixed.
# Stopping and starting an AVD replaces the emulator process: the new one has a
# different window handle, and it may land on a different adb port, so the old
# console connection is dead too. The mirror used to exit when the emulator
# exited, which meant stopping an AVD from the UI took the mirror down with it
# and starting it again left the page on "reconnecting" - the controls were
# unusable for the workflow they exist to support.
$script:EmuProc = $qemu
$script:EmuHwnd = $hwnd
$script:ConsolePort = 5554
$script:EmuLost = $false

# Where the emulator window was last on screen, and whether the user parked it.
# Kept on disk because both facts used to live in the process: `Restart Server`
# then left the window parked while "Show" reported "shown" without moving it,
# and a restarted emulator came back on screen with the preference forgotten.
# LOCALAPPDATA, so it outlives a checkout, a rebuild and a VS Code update.
$script:WindowStatePath = Join-Path $env:LOCALAPPDATA 'avd-mirror\window.json'

# FLAG_SECURE policy. Off by default: the capture is host-side and shows secure
# windows on purpose - that is the point of mirroring a banking app. Turning it
# on makes the mirror behave the way a screenshot of the guest would, i.e. it
# stops showing anything while a secure window is in front. The extension owns
# the setting and pushes it here (/secure), so every surface agrees.
$script:HonourSecure = $false
$script:SecureNow = $false
$script:SecureAt = [datetime]::MinValue

# --- adb + emulator console --------------------------------------------------
# Touch is injected through the emulator console ("event send") instead of
# `adb shell input`: only the console can emit raw multi-touch (MT protocol B)
# events, which is what makes pinch/spread and two-finger gestures work at all.
# `adb shell input` is single-pointer only, and `sendevent` is SELinux-blocked.
$adbExe = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adbExe)) { $adbExe = 'adb' }

function Invoke-Adb {
  param([string[]]$Arguments)
  Invoke-Native { & $adbExe @Arguments }
}

# The *rotated* guest size, which is what the page needs to map its pixels onto
# guest coordinates. `wm size` only ever reports the physical panel (1080x2280),
# so it is useless once the guest is rotated - the display is 2280x1080 in
# landscape while wm size still says 1080x2280, and every tap would land at the
# wrong guest pixel. `dumpsys window displays` reports the current frame as
# cur=WxH, which follows rotation.
function Get-GuestSize {
  try {
    $out = (Invoke-Adb -Arguments @('shell', 'dumpsys', 'window', 'displays') | Out-String)
    $m = [regex]::Match($out, 'cur=(\d+)x(\d+)')
    if ($m.Success) { return $m.Groups[1].Value + 'x' + $m.Groups[2].Value }
  } catch { }
  # Fall back to the physical size; still correct while the guest is portrait.
  try {
    $out = (Invoke-Adb -Arguments @('shell', 'wm', 'size') | Out-String)
    $ms = [regex]::Matches($out, '(\d+)x(\d+)')
    if ($ms.Count -gt 0) { return $ms[$ms.Count - 1].Groups[1].Value + 'x' + $ms[$ms.Count - 1].Groups[2].Value }
  } catch { }
  return '1080x2280'
}

# Current guest orientation as 0/1/2/3 (portrait/90/180/270). The page needs it so
# the on-screen keys can rotate with the display instead of staying in portrait
# places. Read from the display, not from user_rotation: the setting can read
# back a value the display never applied.
function Get-GuestRotation {
  try {
    $out = (Invoke-Adb -Arguments @('shell', 'dumpsys', 'display') | Out-String)
    $m = [regex]::Match($out, 'mCurrentOrientation=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
  } catch { }
  return 0
}

# Is the window in front of the guest FLAG_SECURE?
#
# FLAG_SECURE is enforced inside the guest (SurfaceFlinger), and there is no
# setting or property that relaxes it: `screencap` simply refuses, writing a
# 0-byte file on Android 14, and a rooted framework patch is the only way to
# turn it off. The host-side capture never asks the guest for a screenshot, so
# it sees the pixels anyway - which is what makes an *option* possible here at
# all: the mirror can choose to behave like the screenshot would.
#
# The flag shows up on the focused window's attrs:
#   mCurrentFocus=Window{2f8a4c1 u0 com.tinder/...}
#   Window #3 Window{2f8a4c1 u0 com.tinder/...}
#     mAttrs=Window{...} ty=APPLICATION ... fl=LAYOUT_IN_SCREEN SECURE ...
# so the window is located by the hash in mCurrentFocus and only that block is
# searched. A `SECURE` line elsewhere (a hidden window, a system overlay) must
# not blank the mirror.
#
# `dumpsys window`, not `dumpsys window windows`: the narrower form does not
# print mCurrentFocus at all on Android 14 - it only has the per-window blocks,
# so there was no way to say *which* window the SECURE line belonged to. The
# full dump carries both sections and costs the same (~75 ms).
#
# That is far too much to pay per frame, so the answer is cached for a second
# and only ever asked for when the user has turned the option on. Off, this
# costs a single boolean test.
function Test-FlagSecure {
  if (-not $script:HonourSecure) { return $false }
  if (([datetime]::UtcNow - $script:SecureAt).TotalMilliseconds -lt 1000) { return $script:SecureNow }
  $script:SecureAt = [datetime]::UtcNow
  $script:SecureNow = $false
  try {
    $lines = @(Invoke-Adb -Arguments @('shell', 'dumpsys', 'window'))
    $hash = ''
    foreach ($ln in $lines) {
      $m = [regex]::Match($ln, 'mCurrentFocus=Window\{(\S+)')
      if ($m.Success) { $hash = $m.Groups[1].Value; break }
    }
    # No focus (a headless or just-booted guest) means no secure window is up.
    if (-not $hash) { return $false }
    $inBlock = $false
    foreach ($ln in $lines) {
      if ($ln -match '^\s*Window #\d+ Window\{') {
        $inBlock = $ln.Contains($hash)
      }
      elseif ($inBlock -and $ln -match '\bfl=.*\bSECURE\b') {
        $script:SecureNow = $true
        break
      }
    }
  } catch { }
  return $script:SecureNow
}

# Rotate the guest display. Two steps, and both are needed on this emulator:
# `wm fixed-to-user-rotation enabled` first, because with it disabled the guest
# ignores user_rotation entirely - the setting stores fine and reads back
# correctly, yet mCurrentOrientation stays 0 and the frame never changes. Only
# then does `wm user-rotation lock N` (0=portrait, 1=90, 2=180, 3=270) apply.
function Invoke-Rotate {
  param([int]$Rotation)
      # Resolve to an absolute orientation first. The toolbar's "rotate left / right"
      # buttons are *relative* and send rot=+1 / rot=-1; a non-zero value is read as
      # a delta, not an absolute index. Passing a fixed absolute value from the
      # buttons meant a second click re-applied the same orientation instead of
      # advancing to the next one, so rotating twice looked like nothing happened.
      # rot=0 stays absolute (portrait), which is what makes "force portrait" work.
      $cur0 = Get-GuestRotation
      if ($Rotation -ne 0) { $Rotation = ((($cur0 + $Rotation) % 4 + 4) % 4) }
      $Rotation = $Rotation % 4
      [void](Invoke-Adb -Arguments @('shell', 'wm', 'fixed-to-user-rotation', 'enabled'))
    [void](Invoke-Adb -Arguments @('shell', 'wm', 'user-rotation', 'lock', ([string]$Rotation)))
  # The display settles asynchronously; reading the size immediately would still
    # report the previous orientation and leave the page mapping clicks wrongly.
    # Wait for the *exact* orientation, not just for the portrait/landscape parity:
    # rotations 0<->2 are both portrait and 1<->3 are both landscape, so a parity
    # test is satisfied the instant it is asked for - the loop broke out before the
    # guest had turned and returned the old size. Comparing mCurrentOrientation
    # directly is unambiguous.
    $deadline = [datetime]::UtcNow.AddMilliseconds(2500)
    while ([datetime]::UtcNow -lt $deadline) {
      if ((Get-GuestRotation) -eq $Rotation) { break }
      Start-Sleep -Milliseconds 120
    }
        return (Sync-AfterRotation)
                      }

        # Re-derive everything that depends on the guest's orientation: the emulator
        # window's shape, the capturer's crop, and the cached size. Split out of
        # Invoke-Rotate so an orientation changed *outside* the mirror - the emulator's own
        # rotate shortcut, an `adb shell wm user-rotation` from elsewhere - can be
        # reconciled too. Without this the window kept its old aspect and letterboxed the
        # rotated guest, and wgccap kept serving a portrait crop of a landscape display,
        # so the mirror showed a squeezed image and the keys sat on the wrong edges.
        function Sync-AfterRotation {
                $size = Get-GuestSize
                $script:GSW = [int](($size -split 'x')[0])
                $script:GSH = [int](($size -split 'x')[1])
                # The emulator window keeps its old aspect and would letterbox the rotated
                # guest inside itself, so reshape it before the capturer re-reads the crop.
                [void][EmuMirrorWin]::ReshapeToGuest($script:EmuHwnd, $GSW, $GSH)
                Start-Sleep -Milliseconds 400          # let the window settle before cropping
                # The capturer's crop is fixed at its startup, so it must follow the rotation.
                [void](Restart-Capturer -GuestSize $size)
                # Record the orientation the mirror just applied, so the background watcher
                # does not immediately treat the mirror's own rotation as an external one
                # and redo the reshape + capturer restart.
                $script:lastRot = Get-GuestRotation
                        # Reply carries the size *and* the orientation, so the page rotates its
                # keys in the same round trip: "WxH:R".
                return ($size + ':' + $script:lastRot)
                      }

        # Watch the guest for orientation changes the mirror did not make. $lastRot is
        # updated by Invoke-Rotate and Sync-AfterRotation so the reconciler only does
        # work when something else moved the display.
        $script:lastRot = -1
        function Sync-IfRotatedExternally {
          $r = Get-GuestRotation
          if ($r -eq $script:lastRot) { return $false }
          $script:lastRot = $r
          [void](Sync-AfterRotation)
          return $true
        }

$gsize = Get-GuestSize
$GSW = [int](($gsize -split 'x')[0])
$GSH = [int](($gsize -split 'x')[1])

# --- auto-start the WGC fast capturer (page falls back to PrintWindow if not) -
# --gsize lets the capturer crop its frames to the guest display, so the mirror
# maps browser pixels to guest pixels 1:1 (see the crop logic below).
# The build output lives under a versioned folder (net8.0-windows10.0.19041.0),
# so the executable is looked up rather than hard-coded: a change of target
# framework or of the Windows SDK moves it.
$wgccapExe = $null
$wgccapRoot = Join-Path $PSScriptRoot '..\src\wgccap\bin\Release'
if (Test-Path $wgccapRoot) {
  $wgccapFound = Get-ChildItem -Path $wgccapRoot -Filter 'wgccap.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($wgccapFound) { $wgccapExe = $wgccapFound.FullName }
}
function Test-Capturer {
  try {
    return (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8778/health' -TimeoutSec 1).StatusCode -eq 200
  } catch { return $false }
}
# Returns 'ok', 'missing', 'died' or 'timeout'. Start-Process succeeds even when
# the apphost immediately dies - a missing .NET 8 runtime is the usual reason -
# so the startup call verifies the capturer really answers on 8778 instead of
# logging one that was never there, leaving the page merely slow and tinted.
# -Verify is opt-in: Restart-Capturer runs on the request path and does its own
# bounded wait, so it must not pay for a second one here.
function Start-Capturer {
  param([string]$GuestSize, [switch]$Verify)
  if (-not (Test-Path $wgccapExe)) { return 'missing' }
  try {
    Start-Process -FilePath $wgccapExe -ArgumentList '--proc','qemu-system-x86_64','--port','8778','--gsize',$GuestSize -WindowStyle Hidden -ErrorAction Stop
  } catch {
    [Console]::Out.WriteLine("wgccap.exe would not launch: $($_.Exception.Message)")
    return 'died'
  }
  if (-not $Verify) { return 'ok' }
  $deadline = [datetime]::UtcNow.AddSeconds(6)
  while ([datetime]::UtcNow -lt $deadline) {
    if (Test-Capturer) { return 'ok' }
    if (-not (Get-Process wgccap -ErrorAction SilentlyContinue)) { return 'died' }
    Start-Sleep -Milliseconds 150
  }
  return 'timeout'
}
if (-not (Get-Process wgccap -ErrorAction SilentlyContinue)) {
  switch (Start-Capturer -GuestSize $gsize -Verify) {
    'ok'      { Write-Output 'WGC capturer (wgccap) started on http://127.0.0.1:8778/' }
    'missing' { Write-Output 'wgccap.exe not built - PrintWindow fallback only (build src\wgccap for full-rate)' }
    'died'    { Write-Output 'wgccap.exe exited straight away - is the .NET 8 runtime installed? (dotnet --list-runtimes) - PrintWindow fallback only' }
    default   { Write-Output 'wgccap.exe started but never answered on 8778 - PrintWindow fallback only' }
  }
}

# Restart the capturer so its crop follows the guest. wgccap reads --gsize once
# at startup, so after a rotation it would keep serving a portrait crop of a
# landscape guest while the page maps taps with the new landscape size - the
# screen would look right but every click would land in the wrong place. The page
# falls back to PrintWindow on /frame.jpg while the capturer is down.
function Restart-Capturer {
  param([string]$GuestSize)
  if (-not (Test-Path $wgccapExe)) { return $false }
  Get-Process wgccap -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.Kill(); [void]$_.WaitForExit(3000) } catch { }
  }
  [void](Start-Capturer -GuestSize $GuestSize)
  # Wait until it answers again, so the size reported back to the page is really
  # the one the mirror is now capturing.
  $deadline = [datetime]::UtcNow.AddMilliseconds(5000)
  while ([datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 120
    if (Test-Capturer) { return $true }
  }
  return $false
}

# The console listens on the emulator's adb port (emulator-5554 -> 5554). It is
# re-read when the emulator is replaced, so this is only the initial value.
$script:ConsolePort = 5554
try {
  foreach ($line in (Invoke-Adb -Arguments @('devices'))) {
    if ($line -match '^\s*emulator-(\d+)\s+device') { $script:ConsolePort = [int]$Matches[1]; break }
  }
} catch { }

$script:Console = $null

function Close-Console {
  if ($script:Console) {
    try { $script:Console.Client.Close() } catch { }
    $script:Console = $null
  }
}

function Drain-Console {
  if (-not $script:Console) { return }
  try {
    while ($script:Console.Stream.DataAvailable) {
      if ($null -eq $script:Console.Reader.ReadLine()) { Close-Console; return }
    }
  } catch { Close-Console }
}

function Connect-Console {
  $token = ''
  $tokenFile = Join-Path $env:USERPROFILE '.emulator_console_auth_token'
  if (Test-Path $tokenFile) { $token = (Get-Content $tokenFile -Raw).Trim() }
  $c = New-Object System.Net.Sockets.TcpClient
  $c.NoDelay = $true
  $c.Connect('127.0.0.1', $script:ConsolePort)
  $ns = $c.GetStream()
  $w = New-Object System.IO.StreamWriter($ns)
  $w.AutoFlush = $true
  $script:Console = [pscustomobject]@{
    Client = $c
    Stream = $ns
    Writer = $w
    Reader = (New-Object System.IO.StreamReader($ns))
  }
  Start-Sleep -Milliseconds 120
  Drain-Console
  $w.WriteLine("auth $token")
  Start-Sleep -Milliseconds 120
  Drain-Console
}

function Send-Console {
  param([string]$Command)
  Drain-Console
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    try {
      if (-not $script:Console) { Connect-Console }
      $script:Console.Writer.WriteLine($Command)
      return $true
    } catch { Close-Console }
  }
  return $false
}

# Re-point the mirror at the emulator when the one it was started with is gone.
# Called from the request path, which is the only place that runs while the
# emulator is being replaced: the accept loop blocks in AcceptTcpClient() and
# cannot poll. The check is a property read on an already-held process object,
# so it is cheap enough to do on every request.
function Update-EmulatorTarget {
  if ($script:EmuProc -and -not $script:EmuProc.HasExited) { return $true }

  $p = Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) {
    if (-not $script:EmuLost) {
      # Console.Out rather than Write-Output: the output stream is buffered when
      # it is redirected to a file or a pipe, so these lifecycle messages would
      # not appear until the process exited - exactly when they are least
      # useful.
      [Console]::Out.WriteLine('EMULATOR_EXITED - waiting for an emulator to appear')
      [Console]::Out.Flush()
      $script:EmuLost = $true
    }
    return $false
  }
  $script:EmuProc = $p
  $script:EmuHwnd = $p.MainWindowHandle
  $script:EmuLost = $false

  # A freshly started emulator arrives on screen. If the user had parked the last
  # one, park this one too - that is what "maintained across restarts" means.
  try { [void][EmuMirrorWin]::Resume($script:EmuHwnd) } catch { }

  # The console port follows the new emulator's adb port, and the old console
  # connection belongs to the process that just died.
  Close-Console
  $script:ConsolePort = 5554
  try {
    foreach ($line in (Invoke-Adb -Arguments @('devices'))) {
      if ($line -match '^\s*emulator-(\d+)\s+device') { $script:ConsolePort = [int]$Matches[1]; break }
    }
  } catch { }
  try { Connect-Console } catch { }

  # The WGC capturer is bound to the emulator *window*, so a replaced emulator
  # leaves it capturing a window that no longer exists: it stops producing
  # frames and then exits, taking port 8778 with it. The page then fails to
  # fetch and shows "reconnecting" even though the mirror is fine. Restart it
  # against the new window.
  try { [void](Restart-Capturer -GuestSize (Get-GuestSize)) } catch { }

  # Console.Out rather than Write-Output: the output stream is buffered when it
  # is redirected to a file or a pipe, so these lifecycle messages would not
  # appear until the process exited - exactly when they are least useful.
  [Console]::Out.WriteLine("emulator replaced - hwnd=$($script:EmuHwnd) console=$($script:ConsolePort)")
  [Console]::Out.Flush()
  return $true
}

# Keep the WGC capturer alive. It can die on its own - the window it was
# capturing went away, or it crashed - and then the page falls back to
# PrintWindow: slower, and it has the channel-swap tint bug. The check is
# rate-limited so it costs one Get-Process every couple of seconds rather than
# one per request (the page polls at ~100/s).
$script:CapCheckAt = [datetime]::MinValue
$script:CapFailAt = [datetime]::MinValue
function Ensure-Capturer {
  if (([datetime]::UtcNow - $script:CapCheckAt).TotalMilliseconds -lt 2000) { return }
  $script:CapCheckAt = [datetime]::UtcNow
  if (Get-Process wgccap -ErrorAction SilentlyContinue) { return }
  if (-not $script:EmuProc -or $script:EmuProc.HasExited) { return }   # no window to capture
  # A restart waits up to 5 s for /health, and this runs on the request path, so a
  # capturer that keeps failing - one that cannot start at all because the .NET 8
  # runtime is missing - must not be retried on every poll.
  if (([datetime]::UtcNow - $script:CapFailAt).TotalSeconds -lt 30) { return }
  try {
    if (-not (Restart-Capturer -GuestSize (Get-GuestSize))) { $script:CapFailAt = [datetime]::UtcNow }
  } catch { $script:CapFailAt = [datetime]::UtcNow }
}

# --- extended controls -------------------------------------------------------
# The emulator's "Extended Controls" dialog has no console command - `adb emu
# help` lists nothing of the sort - and its toolbar is custom-drawn Qt, so there
# is no HWND to click either. UI Automation is the only handle: the toolbar
# exposes a button with AutomationId 'ToolControls.more_button', and the dialog
# it opens arrives as a top-level window with AutomationId 'ExtendedControls'.
#
# Two traps. The toolbar is not a child of the desktop - it is nested inside the
# emulator window - so its buttons are only found by walking Descendants from the
# root; a Children scan finds nothing. And the dialog's own close button ignores
# InvokePattern, so closing it takes WindowPattern.Close().
$script:UiaReady = $false
function Enable-Uia {
  if ($script:UiaReady) { return $true }
  try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $script:UiaReady = $true
  } catch { }
  return $script:UiaReady
}

# UIA has no id-scoped search, so this filters the whole tree. It costs tens of
# milliseconds and only runs when the user asks for the dialog.
function Find-UiaById {
  param([string]$Id, [int]$TimeoutMs = 0)
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ($true) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $el = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants, $cond)
    if ($el) { return $el }
    if ($TimeoutMs -le 0 -or (Get-Date) -ge $deadline) { return $null }
    Start-Sleep -Milliseconds 150
  }
}

# Bring a UIA element's own window to the foreground. The emulator builds the
# dialog from its background UI thread, so the invoke alone leaves it behind
# whatever the user is looking at; UIA gives the HWND to fix that with the same
# helper the emulator window's "Show" uses.
function Set-UiaForeground {
  param([System.Windows.Automation.AutomationElement]$Element)
  if (-not $Element) { return $false }
  try {
    $h = [IntPtr]$Element.Current.NativeWindowHandle
    if ($h -ne [IntPtr]::Zero) { return [EmuMirrorWin]::BringToFront($h) }
    $Element.SetFocus()
    return $true
  } catch { return $false }
}

# Returns 'opened', 'focused', 'no-emulator', 'no-toolbar' or 'failed:<why>'.
# 'focused' rather than toggling the dialog shut: the button says show, and a
# dialog that is already up (possibly behind the mirror) is what the user wanted
# to see.
function Show-ExtendedControls {
  $script:ControlsFront = $false
  if (-not $script:EmuProc -or $script:EmuProc.HasExited) { return 'no-emulator' }
  if (-not (Enable-Uia)) { return 'failed:no-uia' }
  try {
    $dlg = Find-UiaById 'ExtendedControls'
    if ($dlg) {
      $script:ControlsFront = Set-UiaForeground $dlg
      return 'focused'
    }
    # A freshly booted emulator builds its toolbar late, so wait rather than
    # reporting no-toolbar at the one moment the button is most likely used.
    $more = Find-UiaById 'ToolControls.more_button' 3000
    if (-not $more) { return 'no-toolbar' }
    $inv = $more.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $inv.Invoke()
    # Invoke() only posts the click, and the dialog is built by the emulator's UI
    # thread, so give it a moment before calling it a failure.
    $dlg = Find-UiaById 'ExtendedControls' 2500
    if ($dlg) {
      $script:ControlsFront = Set-UiaForeground $dlg
      return 'opened'
    }
    return 'failed:no-dialog'
  } catch {
    # The message goes straight into a JSON string, so keep it free of quotes
    # and newlines rather than escaping it here.
    return 'failed:' + ($_.Exception.Message -replace '["\r\n]', ' ')
  }
}

# --- touch engine: host pointer state -> MT protocol B events ----------------
# The emulator's touch panel reports 0..32767 on both axes, scaled to the
# display, so guest pixels are converted with (px * 32767 / (dim - 1)).
$script:Slots = @{}       # pointerId -> slot
$script:SlotOwner = @{}   # slot -> pointerId
$script:PointerRaw = @{}  # pointerId -> "rawX,rawY" (skips no-op move frames)
$script:TrackingId = 0
$script:SlotStamp = @{}   # slot -> last time it was refreshed (staleness reaper)

function Get-FreeSlot {
  for ($i = 0; $i -lt 10; $i++) {
    if (-not $script:SlotOwner.ContainsKey($i)) { return $i }
  }
  return -1
}

# Lift every slot the panel exposes, not just the ones this script allocated.
# The slot space is shared with the emulator window's own pointer input, so a
# contact injected elsewhere (or left behind by a dropped connection) is
# invisible to $script:Slots yet still held down in the guest. Sweeping all
# slots is idempotent: lifting an unused slot is a no-op, and a ghost contact
# otherwise makes every later gesture parse as multi-touch.
function Reset-Touch {
  $ev = @()
  for ($s = 0; $s -lt 10; $s++) {
    $ev += "3:47:$s"
    $ev += '3:57:-1'
  }
  $script:Slots = @{}
  $script:SlotOwner = @{}
  $script:PointerRaw = @{}
    $script:SlotStamp = @{}
    Send-Console ('event send ' + (($ev + '0:0:0') -join ' ')) | Out-Null
    return $true
  }

  # A contact only stays down while the page keeps sending frames containing it.
  # If the browser tab is closed, reloaded, or the connection drops mid-gesture,
  # the matching lift never arrives and the finger would stay held forever. Any
  # slot not refreshed within $ReapMs is therefore swept, so a lost lift can never
  # wedge the guest into a permanent two-finger state.
  $script:ReapMs = 1500
  function Reap-StaleSlots {
    if ($script:SlotStamp.Count -eq 0) { return }
    $now = [DateTime]::UtcNow
    $stale = @($script:SlotStamp.GetEnumerator() |
      Where-Object { ($now - $_.Value).TotalMilliseconds -gt $script:ReapMs })
    if ($stale.Count -eq 0) { return }
    $ev = @()
    foreach ($s in $stale) {
      $ev += "3:47:$($s.Key)"
      $ev += '3:57:-1'
      $owner = $script:SlotOwner[$s.Key]
      if ($null -ne $owner) {
        [void]$script:Slots.Remove($owner)
        [void]$script:PointerRaw.Remove($owner)
      }
      [void]$script:SlotOwner.Remove($s.Key)
      [void]$script:SlotStamp.Remove($s.Key)
    }
    Send-Console ('event send ' + (($ev + '0:0:0') -join ' ')) | Out-Null
  }

# $Spec is "id:x:y,id:x:y" in guest pixels; an empty spec lifts every finger.
function Send-TouchState {
  param([string]$Spec)

  $points = @()
  if ($Spec) {
    foreach ($item in ($Spec -split ',')) {
      if (-not $item) { continue }
      $a = $item -split ':'
      if ($a.Count -lt 3) { continue }
      $x = [int]$a[1]
      $y = [int]$a[2]
      if ($x -lt 0) { $x = 0 } elseif ($x -gt $GSW - 1) { $x = $GSW - 1 }
      if ($y -lt 0) { $y = 0 } elseif ($y -gt $GSH - 1) { $y = $GSH - 1 }
      $points += [pscustomobject]@{
        Id   = $a[0]
        RawX = [int][math]::Round($x * 32767.0 / ($GSW - 1))
        RawY = [int][math]::Round($y * 32767.0 / ($GSH - 1))
      }
    }
  }

  $ev = @()
  $alive = @{}
    $now = [DateTime]::UtcNow
    foreach ($p in $points) {
      $alive[$p.Id] = $true
      $raw = "$($p.RawX),$($p.RawY)"
      if ($script:Slots.ContainsKey($p.Id)) {
        $script:SlotStamp[$script:Slots[$p.Id]] = $now
        if ($script:PointerRaw[$p.Id] -ne $raw) {
        $ev += "3:47:$($script:Slots[$p.Id])"
        $ev += "3:53:$($p.RawX)"
        $ev += "3:54:$($p.RawY)"
        $script:PointerRaw[$p.Id] = $raw
      }
    } else {
      $slot = Get-FreeSlot
      if ($slot -lt 0) { continue }
      $script:TrackingId = ($script:TrackingId % 65000) + 1
      $script:Slots[$p.Id] = $slot
      $script:SlotOwner[$slot] = $p.Id
      $script:PointerRaw[$p.Id] = $raw
            $script:SlotStamp[$slot] = $now
      $ev += "3:47:$slot"                       # ABS_MT_SLOT
      $ev += "3:57:$($script:TrackingId)"       # ABS_MT_TRACKING_ID (new contact)
      $ev += "3:53:$($p.RawX)"                  # ABS_MT_POSITION_X
      $ev += "3:54:$($p.RawY)"                  # ABS_MT_POSITION_Y
      $ev += '3:48:24'                          # ABS_MT_TOUCH_MAJOR
      $ev += '3:58:512'                         # ABS_MT_PRESSURE
    }
  }
  foreach ($id in @($script:Slots.Keys)) {
    if (-not $alive.ContainsKey($id)) {
      $ev += "3:47:$($script:Slots[$id])"
      $ev += '3:57:-1'                          # lift this contact
      [void]$script:SlotOwner.Remove($script:Slots[$id])
      [void]$script:PointerRaw.Remove($id)
            [void]$script:SlotStamp.Remove($script:Slots[$id])
            [void]$script:Slots.Remove($id)
    }
  }
  if ($ev.Count -eq 0) { return $true }
  return Send-Console ('event send ' + (($ev + '0:0:0') -join ' '))
}

# --- scripted gestures (used by /input for automation) -----------------------
# Wait until a wall-clock instant, for pacing a gesture.
#
# Start-Sleep -Milliseconds and [Thread]::Sleep both round up to the ~15.6 ms
# Windows timer tick, so a requested 16 ms delay really costs ~31 ms. A gesture
# paced that way runs at roughly twice its intended speed-to-duration ratio: a
# 660 ms swipe lands at ~1.3 s, and since the request loop is serial that stall
# is also dead time for every other input arriving meanwhile. Sleeping the bulk
# of the remaining time and spinning out the last millisecond keeps the gesture
# the length it was asked to be.
function Wait-ForDeadline {
  param([datetime]$Deadline)
  while ($true) {
    $remain = ($Deadline - [datetime]::UtcNow).TotalMilliseconds
    if ($remain -le 0) { return }
    if ($remain -gt 2) { [Threading.Thread]::Sleep([int]($remain - 1)) }
    else { [Threading.Thread]::SpinWait(1) }
  }
}

# Pace a gesture against a wall-clock start rather than a fixed per-step sleep.
# The cost of sending each step is part of the step's budget, so a fixed sleep
# stacks on top of it and stretches the whole gesture; a deadline absorbs the
# send time and only ever waits for whatever is genuinely left.
function Get-StepDeadline {
  param([datetime]$Start, [int]$Ms, [int]$Index, [int]$Steps)
  return $Start.AddMilliseconds($Ms * $Index / [double]$Steps)
}

function Invoke-TouchSwipe {
  param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$Ms)
  $steps = [math]::Min(80, [math]::Max(4, [int]($Ms / 16)))
  $start = [datetime]::UtcNow
  [void](Send-TouchState "1:${X1}:${Y1}")
  for ($i = 1; $i -le $steps; $i++) {
    $f = $i / [double]$steps
    $x = [int]($X1 + ($X2 - $X1) * $f)
    $y = [int]($Y1 + ($Y2 - $Y1) * $f)
      [void](Send-TouchState "1:${x}:${y}")
    Wait-ForDeadline (Get-StepDeadline $start $Ms $i $steps)
  }
  [void](Send-TouchState '')
}

function Invoke-TouchTap {
  param([int]$X, [int]$Y, [int]$Hold = 60)
  $start = [datetime]::UtcNow
  [void](Send-TouchState "1:${X}:${Y}")
  Wait-ForDeadline $start.AddMilliseconds($Hold)
  [void](Send-TouchState '')
}

function Invoke-TouchPinch {
  param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$EX1, [int]$EY1, [int]$EX2, [int]$EY2, [int]$Ms)
  $steps = [math]::Min(80, [math]::Max(4, [int]($Ms / 16)))
  $start = [datetime]::UtcNow
  [void](Send-TouchState "1:${X1}:${Y1},2:${X2}:${Y2}")
  for ($i = 1; $i -le $steps; $i++) {
    $f = $i / [double]$steps
    $ax = [int]($X1 + ($EX1 - $X1) * $f); $ay = [int]($Y1 + ($EY1 - $Y1) * $f)
    $bx = [int]($X2 + ($EX2 - $X2) * $f); $by = [int]($Y2 + ($EY2 - $Y2) * $f)
      [void](Send-TouchState "1:${ax}:${ay},2:${bx}:${by}")
    Wait-ForDeadline (Get-StepDeadline $start $Ms $i $steps)
  }
  [void](Send-TouchState '')
}

# --- emulator panel actions --------------------------------------------------
function Invoke-NavKey {
  param([string]$Key)
  $map = @{
    back    = 'KEYCODE_BACK'
    home    = 'KEYCODE_HOME'
    recents = 'KEYCODE_APP_SWITCH'
    volup   = 'KEYCODE_VOLUME_UP'
    voldown = 'KEYCODE_VOLUME_DOWN'
    power   = 'KEYCODE_POWER'
    menu    = 'KEYCODE_MENU'
    enter   = 'KEYCODE_ENTER'
  }
  if (-not $map.ContainsKey($Key)) { return $false }
  [void](Invoke-Adb -Arguments @('shell', 'input', 'keyevent', $map[$Key]))
  return $true
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

# `input text` reads %s as space; everything outside the safe set is escaped so
# the device shell passes punctuation/literals through untouched.
function Send-Text {
  param([string]$Text)
  if (-not $Text) { return $true }
  $t = $Text -replace ' ', '%s'
  $t = [regex]::Replace($t, "[^A-Za-z0-9_.,@%:/+=\-]", { param($m) '\' + $m.Value })
  [void](Invoke-Adb -Arguments @('shell', "input text $t"))
  return $true
}

# --- native capture helper ---------------------------------------------------
$cs = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

public static class EmuMirrorWin
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref POINT p);
    // PowerShell is DPI-unaware, so it measures the window in virtualised pixels
    // while PrintWindow still renders the guest 1:1 (physical). Switching this
    // thread to per-monitor-DPI-aware makes the metrics match the captured image.
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // Shell taskbar list. Used only to add/remove this window's taskbar button:
    // the window itself stays composed, so the capture is untouched.
    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    class CTaskbarList { }
    [ComImport, Guid("56FDF342-FD6D-11d0-958A-006097C9A090"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITaskbarList
    {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
    }

    const uint PW_RENDERFULLCONTENT = 0x00000002;
    const uint SWP_NOSIZE    = 0x0001;
    const uint SWP_NOMOVE   = 0x0002;
    const uint SWP_NOZORDER  = 0x0004;
    const uint SWP_NOACTIVATE= 0x0010;
    const uint SWP_FRAMECHANGED = 0x0020;
    const int  GWL_EXSTYLE   = -20;
    const int  WS_EX_TOOLWINDOW = 0x00000080;
    const int  SW_RESTORE    = 9;
    const int  SW_SHOWNOACTIVATE = 8;
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    const int  SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
    const int  SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    static RECT lastNormal; static bool haveLast;
    // "shown" promises the window is back on screen, not that it is in front of
    // the editor, and Windows can refuse the activation. The last show reports
    // which of the two happened so a caller can tell.
    public static bool lastFront;
    // A window that is already in the foreground when it is parked must not be
    // mistaken for the user clicking its way back: only a foreground change
    // *after* parking (they focused something else, then this window again) is.
    static bool sawFgOther;

    // --- foreground ----------------------------------------------------------
    // Bringing a window forward is not the same call as moving it: the restore
    // path uses SWP_NOZORDER|SWP_NOACTIVATE, so a "shown" emulator comes back
    // *behind* whatever the user was looking at, and an Extended Controls dialog
    // the emulator builds from its own background UI thread lands the same way.
    //
    // SetForegroundWindow is refused to a process that is not already the
    // foreground one - the mirror server never is, VS Code is - and a refused
    // call only flashes the taskbar button. Attaching to the input queues is the
    // standard way round that: while attached, this thread is treated as one of
    // them for the duration of the call, so both the foreground thread and the
    // target window's own thread are attached. If even that is refused the
    // window is raised in the z-order instead, which is visible even when
    // Windows keeps the activation for itself.
    public static bool BringToFront(IntPtr hwnd)
    {
        try
        {
            if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return false;
            if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
            if (AtForeground(hwnd, 0)) return true;
            SetForegroundWindow(hwnd);
            if (AtForeground(hwnd, 250)) return true;

            uint mine = GetCurrentThreadId();
            IntPtr fg = GetForegroundWindow();
            uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
            uint tgtThread = GetWindowThreadProcessId(hwnd, IntPtr.Zero);
            bool a1 = fgThread != 0 && fgThread != mine && AttachThreadInput(mine, fgThread, true);
            bool a2 = tgtThread != 0 && tgtThread != mine && tgtThread != fgThread &&
                      AttachThreadInput(mine, tgtThread, true);
            try
            {
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
            }
            finally
            {
                if (a2) AttachThreadInput(mine, tgtThread, false);
                if (a1) AttachThreadInput(mine, fgThread, false);
            }
            if (AtForeground(hwnd, 250)) return true;

            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            return false;
        }
        catch { return false; }
    }

    // Activation is granted to the *other* thread, so it shows up in
    // GetForegroundWindow only once that thread has run: checking the instant
    // SetForegroundWindow returns reports a failure for a raise that worked.
    static bool AtForeground(IntPtr hwnd, int waitMs)
    {
        for (int waited = 0; ; waited += 15)
        {
            if (GetForegroundWindow() == hwnd) return true;
            if (waited >= waitMs) return false;
            System.Threading.Thread.Sleep(15);
        }
    }

    // User Alt-Tabs / taskbar-clicks an off-screen window -> put it back where it was.
    static void Track(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) return;
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return;
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        bool off = r.R <= vx || r.L >= vx + vw || r.B <= vy || r.T >= vy + vh;
        if (!off) { lastNormal = r; haveLast = true; sawFgOther = false; EnforceParked(hwnd); return; }
        if (GetForegroundWindow() != hwnd) { sawFgOther = true; return; }
        if (haveLast && sawFgOther)
        {
            SetWindowPos(hwnd, IntPtr.Zero, lastNormal.L, lastNormal.T,
                         lastNormal.R - lastNormal.L, lastNormal.B - lastNormal.T,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            Stealth(hwnd, false);                    // back on screen, back in the shell
            sawFgOther = false;
            // Brought back by hand, so it is not the state to resume.
            ParkState(false, lastNormal, true);
        }
    }

    // Minimized windows cannot be captured: restore quietly and park off-screen.
    static void Rescue(IntPtr hwnd)
    {
        IntPtr prev = GetForegroundWindow();
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        if (IsIconic(hwnd)) return;               // still stuck; retry next frame
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return;
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        if (!stateLoaded) LoadState();
        ParkState(parkedSaved, r, true);  // a minimized window is parked too: resume it parked
        SetWindowPos(hwnd, IntPtr.Zero, vx + vw + 100, 200,
                     r.R - r.L, r.B - r.T, SWP_NOZORDER | SWP_NOACTIVATE);
        Stealth(hwnd, true);
        sawFgOther = (prev != hwnd);
        if (prev != IntPtr.Zero && prev != hwnd) SetForegroundWindow(prev);
    }

    // --- hide / show ---------------------------------------------------------
    // Both capture paths read the window's DWM surface, so a window that is
    // *gone* from the compositor stops producing frames: SW_HIDE froze WGC
    // outright (0 frames in 3 s) and resumed on SW_SHOWNOACTIVATE, exactly as
    // minimizing does. Parking the window just outside the virtual screen is
    // the only way to get it out of sight and still capture it - measured at
    // ~53 fps while parked. So "hide" means off-screen, never SW_HIDE.
    static RECT stashRect; static bool haveStash;

    // --- parked state on disk ------------------------------------------------
    // The stash above dies with the process, which made two ordinary restarts
    // lose the window: `Restart Server` left it parked but "Show" returned
    // "shown" without moving it (the rect was gone), and a fresh emulator came
    // back on screen because nothing remembered the user had parked the old one.
    // So the last on-screen rect and the parked flag live in a small file that
    // both paths read back. Written only on a real change, never per frame.
    public static string StatePath = "";
    static RECT savedRect; static bool haveSaved;
    static bool parkedSaved; static bool stateLoaded;

    static void ParkState(bool parked, RECT r, bool useRect)
    {
        if (!stateLoaded) LoadState();
        if (parked == parkedSaved && (!useRect || (haveSaved && r.L == savedRect.L && r.T == savedRect.T && r.R == savedRect.R && r.B == savedRect.B))) return;
        parkedSaved = parked;
        if (useRect) { savedRect = r; haveSaved = true; }
        if (string.IsNullOrEmpty(StatePath)) return;
        try
        {
            var dir = Path.GetDirectoryName(StatePath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            RECT o = haveSaved ? savedRect : new RECT { L = 0, T = 0, R = 0, B = 0 };
            File.WriteAllText(StatePath,
                "{\"parked\":" + (parked ? "true" : "false") +
                ",\"l\":" + o.L + ",\"t\":" + o.T + ",\"r\":" + o.R + ",\"b\":" + o.B + "}\n");
        }
        catch { }
    }

    static void LoadState()
    {
        try
        {
            stateLoaded = true;
            parkedSaved = false;
            if (string.IsNullOrEmpty(StatePath) || !File.Exists(StatePath)) return;
            string t = File.ReadAllText(StatePath);
            var b = Regex.Match(t, "\"parked\"\\s*:\\s*(true|false)");
            if (b.Success) parkedSaved = b.Groups[1].Value == "true";
            var m = Regex.Match(t, "\"l\"\\s*:\\s*(-?\\d+)\\s*,\\s*\"t\"\\s*:\\s*(-?\\d+)\\s*,\\s*\"r\"\\s*:\\s*(-?\\d+)\\s*,\\s*\"b\"\\s*:\\s*(-?\\d+)");
            if (m.Success)
            {
                savedRect = new RECT
                {
                    L = int.Parse(m.Groups[1].Value), T = int.Parse(m.Groups[2].Value),
                    R = int.Parse(m.Groups[3].Value), B = int.Parse(m.Groups[4].Value),
                };
                haveSaved = savedRect.R > savedRect.L && savedRect.B > savedRect.T;
            }
        }
        catch { parkedSaved = false; }
    }

    /// Resume the parked flag for a window that was just adopted (server start, or
    /// the emulator replaced under us). A new window has its own rect, so the old
    /// stash is dropped and the fresh one is what gets remembered.
    public static string Resume(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return "no-emulator";
        haveStash = false;
        LoadState();
        if (!parkedSaved) return "shown";
        return SetHidden(hwnd, true);
    }

    /// Park the window again when the user wants it hidden but it is on screen.
    ///
    /// The parked flag is the user's *choice*, not an observation of where the
    /// window happens to be. A freshly started emulator creates its window on
    /// screen and moves it back there itself once the guest finishes booting, so
    /// "this window is on screen" must not be read as "the user wants it there".
    /// It was, and a hide lasted about a second: the window came back onto the
    /// desktop behind everything, with its taskbar entry already deleted, while
    /// /window answered "shown" - visible only until another window covered it.
    /// Only an explicit show (SetHidden with hide=$false) clears the choice.
    public static string EnforceParked(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return "no-emulator";
        if (!stateLoaded) LoadState();
        if (!parkedSaved) return "shown";
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return "no-emulator";
        if (OffScreen(r)) return "hidden";
        return SetHidden(hwnd, true);
    }

    static bool OffScreen(RECT r)
    {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        return r.R <= vx || r.L >= vx + vw || r.B <= vy || r.T >= vy + vh;
    }

    // --- no taskbar button, no Alt-Tab entry ---------------------------------
    // Parking the window off-screen hides it from the display but leaves a
    // taskbar button and an Alt-Tab entry behind - it reads as "minimized", not
    // as gone. Two shell-level changes remove those traces without touching the
    // window's DWM surface, so the mirror keeps capturing:
    //   * ITaskbarList::DeleteTab drops the taskbar button (AddTab restores it).
    //   * WS_EX_TOOLWINDOW keeps the shell from listing it as a switchable
    //     window, which is what removes it from Alt-Tab.
    // Both are applied and reverted on the same pause/resume transitions as the
    // off-screen parking itself.
    static void Tab(IntPtr hwnd, bool add)
    {
        // ITaskbarList is an STA object and the host thread may be MTA, so the
        // COM call runs on a short lived STA thread; never on the per frame path.
        var t = new Thread(() =>
        {
            try
            {
                var tb = (ITaskbarList)new CTaskbarList();
                tb.HrInit();
                if (add) tb.AddTab(hwnd); else tb.DeleteTab(hwnd);
            }
            catch { }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        t.Join(400);
    }

    static IntPtr stealthHwnd; static bool stealthed;

    // Idempotent, and safe when another process (mirror.ps1 / wgccap) is the one
    // that hid the window: the ex-style bit is the shared source of truth, the
    // flags only stop us from repeating the COM call on every frame.
    static void Stealth(IntPtr hwnd, bool on)
    {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        if (ex == 0) return;                             // window went away
        bool has = (ex & WS_EX_TOOLWINDOW) != 0;
        if (on)
        {
            if (has && stealthed && stealthHwnd == hwnd) return;
            if (!has)
            {
                SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_TOOLWINDOW);
                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0,
                             SWP_FRAMECHANGED | SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
            Tab(hwnd, false);
            stealthed = true; stealthHwnd = hwnd;
            return;
        }
        if (!has && !(stealthed && stealthHwnd == hwnd)) return;   // nothing of ours to undo
        if (has)
        {
            SetWindowLong(hwnd, GWL_EXSTYLE, ex & ~WS_EX_TOOLWINDOW);
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0,
                         SWP_FRAMECHANGED | SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
        Tab(hwnd, true);
        stealthed = false; stealthHwnd = IntPtr.Zero;
    }

    public static string SetHidden(IntPtr hwnd, bool hide)
    {
        try
        {
            SetThreadDpiAwarenessContext(new IntPtr(-4));
            if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return "no-emulator";
            // A minimized window can be neither captured nor parked. Restoring it
            // is what the rescue path does anyway; do not fail the request for it.
            if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return "failed:GetWindowRect";
            int w = r.R - r.L, h = r.B - r.T;
            if (w <= 0 || h <= 0) return "failed:size";

            if (hide)
            {
                if (!OffScreen(r)) { stashRect = r; haveStash = true; }
                int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
                int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
                if (!SetWindowPos(hwnd, IntPtr.Zero, vx + vw + 100, vy + 200, w, h,
                                  SWP_NOZORDER | SWP_NOACTIVATE)) return "failed:SetWindowPos";
                Stealth(hwnd, true);
                sawFgOther = (GetForegroundWindow() != hwnd);
                // Remember the on-screen rect, not the parking spot: that is what
                // "Show" needs, and it has to outlive this process.
                ParkState(true, stashRect, haveStash);
                return "hidden";
            }
            Stealth(hwnd, false);                    // undo it even if we cannot re-park
            sawFgOther = false;
            RECT target = haveStash ? stashRect : savedRect;
            bool canRestore = haveStash || (haveSaved && savedRect.R > savedRect.L && savedRect.B > savedRect.T);
            // A saved rect on a monitor that is no longer attached would restore
            // the window to nowhere: park it somewhere visible instead.
            if (canRestore && (target.R - target.L <= 0 || target.B - target.T <= 0 || OffScreen(target))) canRestore = false;
            if (!canRestore)
            {
                // Nothing sensible to restore to - a first run that finds the
                // window parked by somebody else. Put it at a visible default
                // rather than reporting "shown" over an off-screen window, which
                // is what left it unreachable.
                int dx = GetSystemMetrics(SM_XVIRTUALSCREEN) + 80, dy = GetSystemMetrics(SM_YVIRTUALSCREEN) + 80;
                target = new RECT { L = dx, T = dy, R = dx + w, B = dy + h };
            }
            if (!SetWindowPos(hwnd, IntPtr.Zero, target.L, target.T,
                              target.R - target.L, target.B - target.T,
                              SWP_NOZORDER | SWP_NOACTIVATE)) return "failed:SetWindowPos";
            ParkState(false, target, true);
            // "Show" means show me, not "put it back somewhere behind the editor":
            // the move above deliberately does not activate, so the window is
            // raised and focused here.
            lastFront = BringToFront(hwnd);
            return "shown";
        }
        catch (Exception ex) { return "failed:" + ex.GetType().Name; }
    }

    // Report what is true *now* rather than what this process last did: the user
    // can click the parked window's taskbar entry, and Track() then brings it
    // back on screen without telling anyone.
    public static string HiddenState(IntPtr hwnd)
    {
        try
        {
            if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return "no-emulator";
            SetThreadDpiAwarenessContext(new IntPtr(-4));
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return "no-emulator";
            return OffScreen(r) ? "hidden" : "shown";
        }
        catch { return "no-emulator"; }
    }

    // The guest display sits inside the captured window as its client area:
    // PrintWindow returns the whole window, so the frame must be cropped to the
    // client rect or mirrored touches would be shifted up by the chrome height.
    static bool ClientRectIn(Bitmap bmp, IntPtr hwnd, int gsw, int gsh, out Rectangle cr)
    {
        cr = Rectangle.Empty;
        RECT wr, cl; POINT org = new POINT();
        if (!GetWindowRect(hwnd, out wr)) return false;
        if (!GetClientRect(hwnd, out cl)) return false;
        if (!ClientToScreen(hwnd, ref org)) return false;
        int cw = cl.R - cl.L, ch = cl.B - cl.T;
        if (cw <= 0 || ch <= 0) return false;

        int dw = cw, dh = ch, ox = 0, oy = 0;
        if (gsw > 0 && gsh > 0)                            // centre the display if letterboxed
        {
            double s = Math.Min((double)cw / gsw, (double)ch / gsh);
            dw = (int)Math.Round(gsw * s); dh = (int)Math.Round(gsh * s);
            ox = (cw - dw) / 2; oy = (ch - dh) / 2;
        }
        int x = Math.Max(0, org.X - wr.L) + ox;
        int y = Math.Max(0, org.Y - wr.T) + oy;
        int w = Math.Min(dw, bmp.Width - x), h = Math.Min(dh, bmp.Height - y);
        if (w <= 8 || h <= 8) return false;
        cr = new Rectangle(x, y, w, h);
        return true;
    }

    // Resize the emulator window's client area to the guest's aspect ratio.
        // Rotation changes the guest from portrait to landscape, but the emulator
        // window keeps its old shape and simply letterboxes the rotated guest inside
        // it - so the capturer crops a thin landscape strip in the middle of a tall
        // window, and the mirror shows a squeezed image. Preserving the window's
        // current client area as the limit keeps it on screen and only ever shrinks
        // the long edge, so a rotation can never push the window off the desktop.
        public static bool ReshapeToGuest(IntPtr hwnd, int gsw, int gsh)
        {
            if (gsw <= 0 || gsh <= 0) return false;
            try
            {
                SetThreadDpiAwarenessContext(new IntPtr(-4));   // PER_MONITOR_AWARE_V2
                if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
                RECT wr, cl;
                if (!GetWindowRect(hwnd, out wr)) return false;
                if (!GetClientRect(hwnd, out cl)) return false;
                int cw = cl.R - cl.L, ch = cl.B - cl.T;
                if (cw <= 0 || ch <= 0) return false;

                // Keep the client area's longest edge, re-derive the other from the
                // guest aspect. Never grow past what fits the virtual desktop.
                int limit = 4000;
                int nw, nh;
                if ((long)cw * gsh >= (long)ch * gsw) { nh = ch; nw = (int)Math.Round((double)ch * gsw / gsh); }
                else { nw = cw; nh = (int)Math.Round((double)cw * gsh / gsw); }
                if (nw <= 0 || nh <= 0) return false;

                int frameW = wr.R - wr.L, frameH = wr.B - wr.T;
                int addW = nw - cw, addH = nh - ch;         // client delta -> window delta
                int winW = frameW + addW, winH = frameH + addH;
                if (winW < 120 || winH < 120) return false;
                if (winW > limit || winH > limit) return false;

                return SetWindowPos(hwnd, IntPtr.Zero, wr.L, wr.T, winW, winH,
                                    SWP_NOZORDER | SWP_NOACTIVATE);
            }
            catch { return false; }
        }

        public static byte[] Capture(IntPtr hwnd, bool rescue, int quality, int gsw, int gsh)
        {
        try
        {
            SetThreadDpiAwarenessContext(new IntPtr(-4));   // PER_MONITOR_AWARE_V2
            Track(hwnd);
            if (rescue && IsIconic(hwnd)) Rescue(hwnd);
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return null;
            int w = r.R - r.L, h = r.B - r.T;
            if (w <= 0 || h <= 0) return null;

            byte[] jpeg;
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    IntPtr hdc = g.GetHdc();
                    try     { PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT); }
                    finally { g.ReleaseHdc(hdc); }
                }

                ImageCodecInfo jpegCodec = null;
                foreach (var c in ImageCodecInfo.GetImageEncoders())
                    if (c.MimeType == "image/jpeg") { jpegCodec = c; break; }
                if (jpegCodec == null) return null;

                Rectangle cr;
                if (ClientRectIn(bmp, hwnd, gsw, gsh, out cr))
                {
                    using (var crop = new Bitmap(cr.Width, cr.Height, PixelFormat.Format32bppArgb))
                    {
                        using (var g2 = Graphics.FromImage(crop))
                            g2.DrawImage(bmp, new Rectangle(0, 0, cr.Width, cr.Height), cr, GraphicsUnit.Pixel);
                        using (var ms = new MemoryStream())
                        {
                            using (var ep = new EncoderParameters(1))
                            {
                                ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                                crop.Save(ms, jpegCodec, ep);
                            }
                            jpeg = ms.ToArray();
                        }
                    }
                }
                else
                {
                    using (var ms = new MemoryStream())
                    {
                        using (var ep = new EncoderParameters(1))
                        {
                            ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                            bmp.Save(ms, jpegCodec, ep);
                        }
                        jpeg = ms.ToArray();
                    }
                }
            }
            return jpeg;
        }
        catch { return null; }
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing
[EmuMirrorWin]::StatePath = $script:WindowStatePath

# Resume the parked state the last run left behind: a server restart that comes
# back to a hidden window should keep it hidden (and, more importantly, able to
# come back - the rect is what "Show" was missing).
try {
  $resumed = [EmuMirrorWin]::Resume($script:EmuHwnd)
  if ($resumed -eq 'hidden') {
    [Console]::Out.WriteLine('WINDOW_RESUMED_HIDDEN - the emulator was parked when the server last ran')
    [Console]::Out.Flush()
  }
} catch { }

# --- page served at / --------------------------------------------------------
$html = @'
<!doctype html><html><head><meta charset="utf-8"><title>AVD Mirror</title>
<style>
 html,body{margin:0;height:100%;background:var(--page);color:#c9d1d9;font:12px system-ui,sans-serif;overflow:hidden}
 /* #wrap is the containing block for the absolutely positioned soft-key bar, and
      carries the surface that shows through wherever the screen is letterboxed.
      --barh is the soft-key bar's height, declared once and consumed by both the
      bar and the reserved strip below the stage so they can never drift apart.
       The page must not scroll (overflow:hidden on html/body): with a scrollbar
       the content box is 15.2 px shorter than the panel, the stage shrinks by that
       much, and every measurement that corrected the bar shifted it by 15.2 px
       again - so it alternated between sitting over the screen and hanging off
       the bottom, permanently. */
   #wrap{display:flex;flex-direction:column;height:100%;position:relative;background:var(--bezel);--barh:38px}
   /* #stage holds the image and the rotating #keylayer. The soft-key bar reserves
        room on whichever edge the current rotation puts it, applied as padding on
        #stage from JS (reserveForRotation). It is set from the rotation index, never
        from a measurement, so it cannot form a layout feedback loop - #keylayer is
        absolutely positioned and never changes #stage's size. */
      /* #stage holds the image and the rotating #keylayer. The soft-key bar reserves
           room on whichever edge the current rotation puts it, applied as padding on
           #stage from JS (reserveForRotation). It is set from the rotation index, never
           from a measurement, so it cannot form a layout feedback loop - #keylayer is
           absolutely positioned and never changes #stage's size. */
            #stage{position:relative;flex:1;min-height:0;display:flex;box-sizing:border-box}
 /* Toolbar chrome is drawn from VS Code's own colour variables, so the panel
    belongs to the editor in a light theme as well as a dark one.
    The *surround* - the letterbox the screen is fitted into, the screen field
    behind the frame, and the strip the soft keys sit on - is not black any more.
    It is transparent, and --page is what shows through: the same surface the
    toolbar is painted with. So the phone sits in the panel instead of inside a
    black box that ignores the theme, and the band above and beside it read as
    one continuous surface. In a plain browser tab --page falls back to the
    GitHub-dark hex the page started with, so the surround stays dark there.
    The hardware keys keep their own hard-coded near-black bodies on purpose -
    those are keys, not surface, and they must read as objects on whatever the
    surface is. */
 :root{
  /* --page     the document behind the toolbar, and what the transparent
                surround shows through to
     --bezel    the letterbox / screen field: transparent, so --page is visible
     --softkey  the strip the three nav keys sit on; #navbar::before darkens it
                one shade so it reads as the phone's chin, not as empty panel
     The webview that wraps this page sets --page:transparent so VS Code's own
     background shows through instead - see MirrorViewProvider._html. */
  --page:var(--tb-bg);
  --bezel:transparent;
  --softkey:var(--tb-bg);
  --tb-bg:var(--vscode-sideBar-background,#161b22);
  --tb-fg:var(--vscode-foreground,#c9d1d9);
  --tb-border:var(--vscode-panel-border,#30363d);
  --tb-btn:var(--vscode-button-secondaryBackground,#21262d);
  --tb-btn-fg:var(--vscode-button-secondaryForeground,#c9d1d9);
  --tb-btn-hover:var(--vscode-button-secondaryHoverBackground,#30363d);
  --tb-accent:var(--vscode-button-background,#1f6feb);
  --tb-accent-fg:var(--vscode-button-foreground,#fff);
  --tb-muted:var(--vscode-descriptionForeground,#8b949e);
  --tb-ok:#3fb950;--tb-warn:#d29922;--tb-err:#f85149;
 }
 /* Three zones, left to right: the tool strip, the AVD control, the help button.
    Only the strip may shrink - min-width:0 plus its own horizontal scroll - and
    the other two are pinned. "Start an emulator" is the reason this panel
    exists, so it must never be the thing that scrolls out of reach; that is
    exactly the bug the help button had, and the reason it was moved out of the
    strip already. */
 #barrow{display:flex;align-items:stretch;background:var(--tb-bg);border-bottom:1px solid var(--tb-border)}
 #bar{flex:1 1 auto;min-width:64px;padding:6px 10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
 #m{flex:1;min-height:0;object-fit:contain;background:var(--bezel);cursor:crosshair;user-select:none;-webkit-user-select:none;touch-action:none;outline:none}
 /* The captured frame is not a clean rectangle: the emulator's device skin
    rounds the display's bottom two corners, so a light arc sits *inside* the
    frame at each of them and the screen reads as rounded where it should be a
    hard edge - most obvious now that the soft-key bar's hairlines run up to it.
    CSS can hide pixels but never add them, so each bottom corner is covered by a
    canvas holding the frame's own content from just above the arc (see
    patchCorners). Copying real pixels keeps the patch invisible whatever the
    guest paints there; a guessed flat colour would show as a dot the moment the
    bottom of the screen is not uniformly dark.
    Positioned from the displayed rect (--imx/--imw/--imy/--imh, set by
    layoutNav) rather than the stage box, so the patches follow the screen when
    the letterbox moves, and pointer-events:none keeps every tap and drag going
    to #m underneath. --sqpx must stay larger than the arc (about 6 frame px). */
 .sqcorner{--sqpx:12px;position:absolute;width:var(--sqpx);height:var(--sqpx);pointer-events:none}
 #sqL{left:var(--imx);top:calc(var(--imy) + var(--imh) - var(--sqpx))}
 #sqR{left:calc(var(--imx) + var(--imw) - var(--sqpx));top:calc(var(--imy) + var(--imh) - var(--sqpx))}
 /* Status is a state *dot* plus text, and the text truncates instead of shoving
    the controls along. "reconnecting... (no emulator running)" is long enough to
    reflow the whole strip on its own, and it reflows again the moment it clears;
    the dot carries the state and the title keeps the full string. Red is
    reserved for a lost connection - a cold start is not an error, and painting
    it red made every normal connect look like a failure. */
 #status{display:inline-flex;align-items:center;gap:5px;flex:0 1 auto;min-width:64px;max-width:190px}
 #dot{display:block;width:7px;height:7px;border-radius:50%;background:var(--tb-muted);flex:0 0 auto}
 #status[data-state="live"] #dot{background:var(--tb-ok)}
 #status[data-state="idle"] #dot{background:var(--tb-warn)}
 #status[data-state="error"] #dot{background:var(--tb-err)}
 #status[data-state="error"] #st{color:var(--tb-err)}
 #st{color:var(--tb-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
 /* Telemetry, not controls: muted, and given fixed widths so a frame counter
    going 9 -> 10 -> 100 does not shove every button to its right. */
 #stats{display:inline-flex;align-items:center;gap:8px;color:var(--tb-muted);opacity:.7;
        font-variant-numeric:tabular-nums;white-space:nowrap;flex:0 1 auto;min-width:0}
 #stats #src{min-width:3.2ch}
 #stats #fps{min-width:5.2ch;text-align:right}
 #stats #dim{min-width:9.2ch;text-align:right}
 #inp{color:var(--tb-warn)}
 #bar button,#avdbar button{background:var(--tb-btn);color:var(--tb-btn-fg);border:1px solid var(--tb-border);
   border-radius:5px;padding:2px 7px;font:12px system-ui,sans-serif;cursor:pointer;line-height:16px}
 #bar button:hover,#avdbar button:hover:not(:disabled){background:var(--tb-btn-hover)}
 /* Keyboard focus had no styling at all - ~10 buttons and not one visible focus
    ring, so tabbing through the panel was invisible. */
 #bar button:focus-visible,#avdbar button:focus-visible,#avdbar select:focus-visible,
 #navbar button:focus-visible,#pwr:focus-visible,.volkey:focus-visible,#helpbtn:focus-visible{
   outline:2px solid var(--vscode-focusBorder,#58a6ff);outline-offset:1px}
 /* The hide toggle is a state, not a momentary action: the emulator window is
    currently parked off-screen. Blue is the accent, and it means "active" -
    the same blue the AVD button uses for its primary action. */
 #bar button[aria-pressed="true"]{background:var(--tb-accent);border-color:var(--tb-accent);color:var(--tb-accent-fg)}
 #bar button[aria-pressed="true"]:hover{filter:brightness(1.15)}
  /* Soft nav keys sit under the screen, centred on 25/50/75% of the *displayed
     guest image* rather than the window: the image is object-fit:contain, so
     whenever there are side letterboxes the two widths differ and anchoring to
     the window would drift the keys off the guest's own nav positions. --imx/--imw
     carry the letterbox offset and displayed width, set by layoutNav(). */
  /* The bar itself is transparent and the strip colour is painted by ::before.
     #keylayer is sized to the *displayed guest screen*, so this bar's box is
     already exactly as wide as the screen and ::before needs no --imx/--imw:
     left:0/right:0 spans the screen, not the window. (An earlier version of this
     comment claimed the strip was positioned from those vars; it never was.)

     That width is why the strip needs its own outline. Now that the letterbox is
     transparent and the strip is --tb-bg, the two are the same colour, so the bar
     reads as spanning the whole panel instead of belonging to the phone. The
     left/right hairlines mark the screen's edges, which are also the bar's ends,
     and together with border-top they close the bar into a U under the screen.
     box-sizing keeps the hairlines inside the screen width - with content-box the
     box grew 2 px wider than the screen it is supposed to sit under. In landscape
     the layer's rotation carries these two lines onto the screen's top and bottom
     physical edges, which is right: those are the edges the bar runs along. */
  /* The bar's top edge is pinned to the bottom of the displayed guest screen via
       `top`, set by layoutNav(). It used to sit in normal flow below the stage, so
       its top edge was the *stage's* bottom edge - which only coincided with the
       screen's once the stage happened to grow to fit exactly. Any vertical
       letterbox left a black band between the screen and the bar.
       `top` is absolute rather than a negative margin: a margin would change the
       space the stage occupies, which changes the letterbox, which changes the
       margin - a feedback loop that never settles. */
    /* All on-screen keys live in one layer, #keylayer, sized to the *unrotated*
         guest screen and rotated by the current orientation. Rotating the whole layer
         means the keys land on the correct physical edges as the display turns: the nav
         bar stays at the device's bottom edge, power and volume on their sides. The
         page sets --kx/--ky (top-left), --kw/--kh (size), --kr (rotate deg) in
         layoutNav() from the displayed screen rect and the rotation. Keys are placed
             in portrait coordinates below; the transform does the rest.

             pointer-events:none is essential, not cosmetic. The layer's box is exactly
             the displayed screen rect, so with the default pointer-events:auto it became
             the hit target for the whole screen and swallowed every tap, drag and wheel
             event - all input to the guest died silently (elementFromPoint returned
             #keylayer, not #m). The layer must pass events through to #m underneath;
             only the key buttons themselves take pointer events again. */
          #keylayer{position:absolute;left:var(--kx);top:var(--ky);width:var(--kw);height:var(--kh);
           transform:rotate(var(--kr,0deg));transform-origin:center center;pointer-events:none}
          #keylayer button,#keylayer a{pointer-events:auto}
    /* The bar hangs *below* the layer in portrait coordinates (top:100%), so after the
       layer is rotated it lands just outside the matching physical edge of the
       screen - bottom in portrait, left in landscape, and so on - and never
       overlaps the guest display. Anchoring it with bottom:0 instead would put
       it *on* the screen's last --barh pixels, and the bar's top edge would
       read as 38 px above the screen bottom rather than flush with it. */
        #navbar{position:absolute;left:0;right:0;top:100%;height:var(--barh);background:var(--bezel)}
      #navbar::before{content:'';position:absolute;top:0;bottom:0;left:0;right:0;box-sizing:border-box;
       background:var(--softkey);
       /* One shade below the surface. At --tb-bg the strip was the exact colour of
          the letterbox above it and of the toolbar, so it read as empty panel
          rather than as the phone's chin - the hairlines were doing all the work of
          separating it. Mixed against black rather than hard-coded, so it darkens
          whatever surface the theme hands it (a light theme gets a grey chin, not a
          black bar); the plain declaration above is what a browser without
          color-mix falls back to. */
       background:color-mix(in srgb,var(--softkey) 60%,#000);
       /* The three hairlines are the fill colour, so the chin is one solid block:
          an outline at any lighter value turned the strip into a framed box. The
          mix is written out twice rather than hoisted into a custom property -
          custom properties are validated lazily, so a browser without color-mix
          would lose the fill *and* the border colour together instead of falling
          back to the plain surface below. */
       border:1px solid var(--softkey);border-bottom:0;
       border-color:color-mix(in srgb,var(--softkey) 60%,#000);
       z-index:0}
  #navbar button{position:absolute;top:50%;transform:translate(-50%,-50%);z-index:1;
   width:28px;height:28px;padding:0;
   display:flex;align-items:center;justify-content:center;
   background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;
   font:14px system-ui,sans-serif;cursor:pointer;line-height:1}
  #navbar button:hover{background:#30363d}
  #navbar button:active{background:#3d444d}
  /* All three soft keys are drawn, not typed. A glyph is locked to the font's
     size, so matching the enlarged Home dot meant replacing the other two as
     well; drawn shapes stay crisp and stay equal at any button size. A fixed
     button height keeps the three keys aligned regardless of icon size. */
  #navbar .ico{width:12px;height:12px;background:currentColor;display:block;flex:0 0 auto}
  #navbar .ico-home{border-radius:50%}
  #navbar .ico-back{clip-path:polygon(100% 0,0 50%,100% 100%)}
  #navbar button[data-nav="back"]{left:25%}
    #navbar button[data-nav="home"]{left:50%}
    #navbar button[data-nav="recents"]{left:75%}
   /* Power and the two volume keys sit in the letterbox, flush against the
           screen's side edges, so they never cover guest content. Inside #keylayer they
           are positioned against the layer's own edges (left/right edge + 40% line),
           which the layer's rotation carries onto the correct physical edges as the
           guest turns.

        This base rule must stay ABOVE the max-height media query below. Both declare
        #pwr,.volkey at equal specificity, so source order decides: with the base rule
        last, its 28x84 size overrode the compact 22x44 and the compact layout silently
        did nothing. */
     #pwr,.volkey{position:absolute;
      width:28px;height:84px;padding:0;z-index:2;
      display:flex;align-items:center;justify-content:center;
      background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;
      font:16px system-ui,sans-serif;cursor:pointer;line-height:1}
         /* The key *bodies* rotate with the layer, exactly as the physical keys do on a
              real device - a 28x84 key in portrait becomes an 84x28 key once the display
              is on its side. Counter-rotating the button itself was the bug this
              replaces: it cancelled the layer rotation for the whole element, so in
              landscape the keys were still measured 28x84 and hung vertically off a
              horizontal edge.

              The glyph inside rotates with the body, too. A real key's face turns with
              the device: the power symbol ends up on its side in landscape, exactly as
              it would if you turned the handset. An earlier version counter-rotated the
              glyph so it stayed upright, which made the key read as a portrait key
              lying on a rotated screen. Neither the span nor the button carries a
              counter-rotation now, so the whole key - frame and symbol - follows
              --kr. The soft-key bar's icons rotate for the same reason. */
              #pwr{left:100%;top:40%;transform:translateY(-50%)}
              #volup{left:0;top:calc(40% - 42px);transform:translate(-100%,-50%)}
              #voldown{left:0;top:calc(40% + 42px);transform:translate(-100%,-50%)}
              #pwr>span,.volkey>span{display:block}
               /* Short viewports (the VS Code side panel is wide but only ~130 px tall) must
         give their space to the screen, not to chrome: the toolbar is a portrait
         phone squeezed by wrapping into three rows, which left the screen itself as a
         ~26x56 px sliver. Collapse everything to single-row, smaller controls. */
      @media (max-height:520px){
       /* The strip scrolls sideways instead of clipping: the panel is far
          narrower than the toolbar's content, and the AVD picker at its right
          end is unreachable if the overflow is simply cut off. The scrollbar is
          kept thin so it costs the screen almost no height. */
       #bar{padding:1px 5px;gap:5px;flex-wrap:nowrap;overflow-x:auto;overflow-y:hidden;
        white-space:nowrap;font-size:10px;scrollbar-width:thin;scrollbar-color:#30363d transparent}
       #bar::-webkit-scrollbar{height:4px}
       #bar::-webkit-scrollbar-track{background:transparent}
       #bar::-webkit-scrollbar-thumb{background:#30363d;border-radius:2px}
       /* Telemetry goes first: it is decoration next to the AVD control pinned
          beside it, and a frame counter should never be what pushes a control
          out of view in a 320 px panel. */
       #stats{display:none}
       #status{max-width:72px;min-width:34px}
       #bar button{padding:0 4px;font-size:10px;line-height:12px}
       #sdir .lbl{display:none}
       #avdbar{max-width:58%;padding:0 4px}
       #avdbar select{max-width:130px;font-size:10px;padding:1px 2px}
       #avdbar button{min-width:0;padding:0 5px;font-size:10px;line-height:12px}
       .avdstate .txt{display:none}
       #helpbtn{width:18px;height:18px;font-size:11px}
       /* --barh must be set on #wrap, the shared ancestor: #stage and #navbar are
          siblings, so overriding it on #navbar alone would resize the bar without
          resizing the space the stage reserves for it. */
       #wrap{--barh:26px}
       #navbar button{width:22px;height:22px;border-radius:5px}
       #navbar .ico{width:9px;height:9px}
       #pwr,.volkey{width:22px;height:44px;font-size:13px}
       #volup{top:calc(40% - 22px)}
       #voldown{top:calc(40% + 22px)}
              /* the compact override must not drop the translate from the base transform */
              #volup,#voldown{transform:translate(-100%,-50%)}
      }
  /* Rotation keys live in the top toolbar next to the scroll-direction toggle.
     They turn the guest display itself, so they belong with the other chrome
     controls rather than in the letterbox with the hardware keys. */
  #rot{display:inline-flex;align-items:center;gap:4px}
  /* The AVD zone: a select that shrinks first, one primary button, and a state
     dot. The dot's word is dropped in the compact layout - the button's own
     label already says what the state is ("Start" / "Stop" / "Booting..."), so
     the word was the most expensive way to repeat it in a 320 px panel. */
  #avdbar{flex:0 1 auto;min-width:0;display:flex;align-items:center;gap:4px;
   padding:0 8px;border-left:1px solid var(--tb-border);max-width:min(62%,300px)}
  #avdbar select{min-width:0;flex:1 1 auto;max-width:190px;background:var(--tb-btn);color:var(--tb-btn-fg);
   border:1px solid var(--tb-border);border-radius:5px;font:12px system-ui,sans-serif;padding:2px 4px}
  #avdbar select:disabled{opacity:.5}
  #avdbar button{flex:0 0 auto;min-width:46px}
  #avdbar button.primary{background:var(--tb-accent);border-color:var(--tb-accent);
   color:var(--tb-accent-fg);font-weight:600}
  #avdbar button.primary:hover:not(:disabled){filter:brightness(1.12)}
  #avdbar button:disabled{opacity:.5;cursor:default}
  .avdstate{display:inline-flex;align-items:center;gap:4px;color:var(--tb-muted);
   font-size:11px;white-space:nowrap;flex:0 0 auto}
  .avdstate::before{content:'';width:6px;height:6px;border-radius:50%;background:var(--tb-muted);flex:0 0 auto}
  .avdstate.running::before{background:var(--tb-ok)}
  .avdstate.starting::before,.avdstate.busy::before{background:var(--tb-warn)}
  .avdstate.none::before{background:var(--tb-err)}
  #rot button{padding:0 6px;font-size:13px;line-height:16px}
  #pwr:hover,.volkey:hover{background:#30363d}
  /* The "no emulator" state. It covers the whole stage so the screen reads as
     blank rather than showing a stale frame, and the on-screen keys are hidden
     with it - they would otherwise float over an empty area. */
  #noemu{position:absolute;inset:0;z-index:5;display:flex;align-items:center;justify-content:center;
   background:var(--bezel);padding:1.5rem;text-align:center}
  #noemu[hidden]{display:none}
  .noemu-box{max-width:34rem}
  .noemu-title{color:#d29922;font-size:15px;font-weight:600;margin-bottom:.45em}
  .noemu-hint{color:var(--vscode-descriptionForeground,#8b949e);font-size:12px;line-height:1.5}
  /* The FLAG_SECURE veil. Same shape as the no-emulator notice and shown the
     same way - instead of the frame, never over it, so the screen cannot be
     mistaken for something live. It sits one layer above #noemu because
     "protected" is the more specific of the two states. */
  #secure{position:absolute;inset:0;z-index:6;display:flex;align-items:center;justify-content:center;
   background:var(--bezel);padding:1.5rem;text-align:center}
  #secure[hidden]{display:none}
  #secure .noemu-title{color:#8b949e}
  #secure code{font-family:var(--vscode-editor-font-family,monospace);font-size:11px}
  /* The help button is a flex sibling of the tool strip, pinned to the right of
     the toolbar row, and its popover is anchored to the top-right of the page.

     It is deliberately not the last item in the tool strip. The compact layout
     - which is what the VS Code panel always uses, since the panel is short -
     collapses the toolbar to a single nowrap row that overflows, and an in-flow
     button at the end of that row lands hundreds of pixels past the right edge
     of the panel, where overflow:hidden clips it away completely and the help
     it offers is unreachable. Out of flow it stays where the eye expects it
     however crowded the toolbar gets. */
  #helpbtn{flex:0 0 auto;align-self:center;margin:0 6px;width:20px;height:20px;padding:0;
   background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:50%;
   font:italic 600 12px/1 Georgia,serif;line-height:1;cursor:pointer}
  #helpbtn:hover{background:#30363d}
  #helpbtn[aria-expanded="true"]{background:#30363d;border-color:var(--vscode-focusBorder,#58a6ff)}
  #helppop{position:absolute;top:0;right:0;z-index:30;box-sizing:border-box;
   width:min(30rem,calc(100% - 1.2rem));
   margin:var(--barpop,2.6rem) .6rem 0 0;padding:.8rem 1rem;background:#161b22;color:#c9d1d9;
   border:1px solid #30363d;border-radius:6px;box-shadow:0 8px 24px rgba(0,0,0,.5);
   font-size:12px;line-height:1.45}
  #helppop[hidden]{display:none}
  #helppop .help-head{font-weight:600;color:#e6edf3;margin-bottom:.5em}
  #helppop dl{display:grid;grid-template-columns:auto 1fr;gap:.25em .9em;margin:0}
  #helppop dt{color:#79c0ff;white-space:nowrap}
  #helppop dd{margin:0;color:#8b949e}
  #helppop .help-foot{margin-top:.7em;padding-top:.5em;border-top:1px solid #30363d;color:#6e7681}
  #pwr:active,.volkey:active{background:#3d444d}
  </style></head>
 <body><div id="wrap">
  <div id="barrow">
  <div id="bar">
   <span id="status" data-state="idle"><i id="dot"></i><span id="st">connecting...</span></span>
   <span id="stats"><span id="src"></span><span id="fps"></span><span id="dim"></span></span>
   <button id="sdir" title="Scroll direction - click to toggle"><span class="lbl">Natural</span> &#8645;</button>
   <span id="rot"><button data-rot="-1" title="Rotate 90&deg; left" aria-label="Rotate left">&#8630;</button><button data-rot="1" title="Rotate 90&deg; right" aria-label="Rotate right">&#8631;</button></span>
   <button id="hideemu" title="Hide the emulator window - it stays off-screen and keeps mirroring" aria-pressed="false">Hide</button>
   <span id="inp"></span>
  </div>
  <!-- The AVD control is a sibling of the tool strip, not its last item, for the
       same reason the help button is: the compact layout makes the strip a single
       nowrap row that overflows, and anything at its far end - the AVD picker
       above all, since starting an emulator is what this panel is for - ends up
       past the right edge of a 320 px panel. Pinned, it stays reachable. -->
  <div id="avdbar"><select id="avdsel" title="Select an AVD" aria-label="Select an AVD"></select><button id="avdgo" class="primary" title="Start the selected AVD">Start</button><span class="avdstate stopped" id="avdstate" title="AVD: stopped"><span class="txt">stopped</span></span></div>
   <!-- The help button is a sibling of the tool strip, not its last item: the
        compact layout makes the strip a single nowrap row that overflows, and
        an in-flow button at the end of it lands past the right edge of the
        panel, clipped away and unreachable. -->
   <button id="helpbtn" title="Show the gesture shortcuts" aria-label="Show the gesture shortcuts" aria-expanded="false">i</button>
  </div>
  <!-- The gesture shortcuts live here rather than in a title attribute on the
       screen, where the hover tooltip covered the content it described. It is a
       sibling of #barrow rather than a child of it: the compact layout clips
       the tool strip, which would clip a popover hanging off it. -->
  <div id="helppop" hidden>
   <div class="help-head">Gestures</div>
   <dl>
    <dt>tap</dt><dd>left click</dd>
    <dt>touch &amp; hold</dt><dd>left press and hold</dd>
    <dt>swipe</dt><dd>left drag</dd>
    <dt>drag (press, hold, then move)</dt><dd>right press and drag</dd>
    <dt>scroll / fling</dt><dd>wheel</dd>
    <dt>scroll sideways</dt><dd>shift + wheel</dd>
    <dt>scroll direction</dt><dd>the &ldquo;Natural&rdquo; toggle in the toolbar</dd>
    <dt>hide the window</dt><dd>the &ldquo;Hide&rdquo; toggle - the emulator keeps mirroring off-screen</dd>
    <dt>pinch &amp; spread</dt><dd>ctrl + drag, or ctrl + wheel</dd>
    <dt>Back</dt><dd>right click (no drag)</dd>
    <dt>Home</dt><dd>middle click</dd>
    <dt>edge drags</dt><dd>system nav gestures</dd>
    <dt>typing</dt><dd>sends keys</dd>
   </dl>
   <div class="help-foot">The on-screen keys act as the device&rsquo;s own hardware keys.</div>
  </div>
  <div id="stage">
  <!-- No title attribute: the hover tooltip listing every gesture shortcut was a
       long multi-line popup over the mirrored screen, and it covered the very
       content it was describing. The `alt` text still names the image for
       assistive technology. -->
  <!-- tabindex exists for the embedded surface's sake: pointerdown calls
       preventDefault() to keep selection and drags out of the gesture, which also
       suppresses the browser's own focus transfer, so img.focus() is the only
       thing that can put keyboard focus here - and an untabbable <img> ignores it.
       On the page's own tab the document already has focus, so this changed
       nothing; framed inside the Embedded Browser, a click without it left focus
       in the parent webview document and every keystroke missed the keydown
       handler (typing did nothing there, while every other surface worked). -->
  <img id="m" tabindex="-1" alt="emulator screen"/>
     <!-- Square the display's bottom corners; see .sqcorner. -->
     <canvas id="sqL" class="sqcorner" aria-hidden="true"></canvas>
     <canvas id="sqR" class="sqcorner" aria-hidden="true"></canvas>
     <!-- Shown instead of the screen while no emulator is running. The last frame
          is cleared, because a stale screen invites the reader to believe the
          emulator is still up. -->
     <div id="noemu" hidden>
       <div class="noemu-box">
         <div class="noemu-title">Emulator is not running</div>
         <div class="noemu-hint">Start an AVD from the AVD picker above, or from the AVD Mirror panel.</div>
       </div>
     </div>
     <!-- Shown instead of the screen while the window in front of the guest sets
          FLAG_SECURE and "Honour FLAG_SECURE" is on. The guest refuses to
          screenshot such a window; honouring the flag is this page choosing to
          do the same, so the mirror looks like a screenshot would. -->
     <div id="secure" hidden>
       <div class="noemu-box">
         <div class="noemu-title">Protected content</div>
         <div class="noemu-hint">The window in front sets FLAG_SECURE, so the guest would not let a
           screenshot through. AVD Mirror is honouring that.<br>
           Turn off <b>Honour FLAG_SECURE</b> (Command Palette, or the
           <code>avdMirror.honourFlagSecure</code> setting) to mirror it anyway.</div>
       </div>
     </div>
     <div id="keylayer">
      <button id="pwr" data-nav="power" title="Power" aria-label="Power"><span>&#9211;</span></button>
      <button id="volup" class="volkey" data-nav="volup" title="Volume up" aria-label="Volume up"><span>+</span></button>
      <button id="voldown" class="volkey" data-nav="voldown" title="Volume down" aria-label="Volume down"><span>&#8722;</span></button>
      <div id="navbar">
       <button data-nav="back" title="Back" aria-label="Back"><span class="ico ico-back"></span></button><button data-nav="home" title="Home" aria-label="Home"><span class="ico ico-home"></span></button><button data-nav="recents" title="Overview" aria-label="Overview"><span class="ico"></span></button>
      </div>
     </div>
    </div>
 <script>
const img=document.getElementById('m'),st=document.getElementById('st'),
      fps=document.getElementById('fps'),dim=document.getElementById('dim'),
      srcEl=document.getElementById('src'),navbar=document.getElementById('navbar'),
      stage=document.getElementById('stage'),kl=document.getElementById('keylayer'),
      sqL=document.getElementById('sqL'),sqR=document.getElementById('sqR'),
      noemuEl=document.getElementById('noemu'),statusEl=document.getElementById('status'),
      secureEl=document.getElementById('secure');

// One place sets the status line, so the dot and the text can never disagree.
// `idle` is neutral rather than an error: red is reserved for a lost connection,
// otherwise every cold start reads as a failure.
function setStatus(text,state){
  st.textContent=text; st.title=text; statusEl.dataset.state=state;
}

// Blank the screen and say why, while no emulator is running. Keeping the last
// frame on screen was misleading - it looked like a live picture of an app that
// had simply frozen. The on-screen keys are hidden with it, since they would
// otherwise float over an empty area.
function veilStage(el,on){
  if(el.hidden===!on) return;
  el.hidden=!on;
  // Either veil hides the keys; only both off brings them back.
  kl.style.visibility=(noemuEl.hidden&&secureEl.hidden)?'':'hidden';
  if(on){
    // Drop the stale frame so the stage is genuinely blank behind the warning.
    if(prev){ URL.revokeObjectURL(prev); prev=null; }
    img.removeAttribute('src');
    dim.textContent='';
    fps.textContent='';      // no frames are arriving, so a frozen rate would lie
    patchCorners();          // the corner patches held pixels from that frame
  }
}
function showNoEmulator(on){ veilStage(noemuEl,on); }
// FLAG_SECURE, when the mirror is set to honour it: the window in front refuses
// screenshots, so the mirror stops showing it rather than pretending otherwise.
// Driven by the fifth field of /rot - the frames come straight from the
// capturer, so this is the only thing that can stop them being painted.
function setProtected(on){
  veilStage(secureEl,on);
  if(on) setStatus('protected content','idle');
}
// WGC (wgccap :8778) captures via Windows.Graphics.Capture - full rate even when
// occluded. Falls back to PrintWindow (/frame.jpg) if wgccap isn't running, and
// re-probes every ~2s to upgrade back automatically.
let prev=null,n=0,t0=performance.now(),mode='wgc',fails=0,probe=0;
const FRAME_MIN_GAP=8;        // ms; only a floor against a hot spin loop, not a rate cap
const FRAME_IDLE_GAP=25;      // ms; base backoff once the screen looks static
let still=0;                  // consecutive polls that returned 304
// Polling hard means asking far more often than the screen actually changes, so
// the loop must not treat "same frame" as a new frame. Re-decoding an identical
// JPEG each poll burns CPU on the main thread -- which is the thread that paints
// and handles input -- and queues older decodes ahead of the frame that is
// actually new, making the mirror lag more the harder it is polled. The
// capturer answers a matching ?since= with 304 and no body, so an idle
// screen costs a header-only round trip and only real changes are decoded.
let frameSeq='';
// The capturer's state, as reported by the server in the /rot reply. null means
// "not known yet".
//
// This matters more than it looks: a refused connection to a dead local port
// takes ~2 s to fail on this machine (measured with a raw TcpClient, not just
// the browser). Polling a capturer that is not there therefore stalls the
// frame loop for two seconds per attempt, which is why the page would sit on
// "connecting..." for several seconds before showing the no-emulator notice.
// The server knows whether the capturer is up, so the page asks instead of
// finding out the slow way.
let capturerUp = null;
// Do not retry a known-dead capturer for this long after a failure.
let wgcDownUntil = 0;

async function grab(url,since){
  // The frame token goes in the query string, not a conditional request header: a
  // custom request header would turn every poll into a CORS preflighted
  // request and add a second round trip to each one.
  const sep=url.includes('?')?'&':'?';
  const u=since?url+sep+'since='+encodeURIComponent(since):url;
  const r=await fetch(u,{cache:'no-store',mode:'cors'});
  if(r.status===304) return null;                  // unchanged - nothing to decode
  if(!r.ok){
    // Carry the server's explanation through, so "no emulator running" reaches
    // the status bar instead of a bare "HTTP 503".
    let d=''; try{ d=await r.text(); }catch(_){}
    throw new Error(d&&d.trim()?d.trim():('HTTP '+r.status));
  }
  const b=await r.blob();
  if(b.size<500) throw new Error('empty frame');
  const seq=r.headers.get('X-Frame-Seq');
  if(seq) frameSeq=seq.replace(/"/g,'');   // keep it a bare number for ?since=
  return b;
}
async function tick(){
  const tReq=performance.now(); let live=false, gotFrame=false;
  // Honouring FLAG_SECURE with a secure window in front: ask for nothing at all,
  // so the capturer is not even consulted and no secure pixels reach the page.
  // The 1.5 s /rot poll is what lifts the veil again.
  if(!secureEl.hidden){ setTimeout(tick,400); return; }
  try{
    let b=null, got=false, srcName='';
    // Skip the WGC attempt entirely while the server says the capturer is down,
    // and back off for a few seconds after it fails. A refused local port takes
    // ~2 s to fail, so probing a dead capturer every tick would stall the
    // frame loop and delay the no-emulator notice by seconds.
    const tryWgc = (mode==='wgc') && (capturerUp!==false) && (Date.now()>=wgcDownUntil);
    if(tryWgc){
      try{ b=await grab('http://127.0.0.1:8778/frame.jpg?t='+Date.now(),frameSeq); got=true; srcName='WGC'; capturerUp=true; }
      catch(e){
        // A network-level failure means the capturer is not listening at all -
        // it died with the emulator window it was capturing. That is not a
        // transient blip, so fall through to the mirror's own endpoint
        // immediately instead of after three attempts: otherwise the page
        // reads "reconnecting" for a moment before discovering the real
        // reason, which is that no emulator is running.
        const netErr=/Failed to fetch|NetworkError|load failed/i.test(e&&e.message?e.message:String(e));
        if(netErr){ mode='pw'; fails=0; capturerUp=false; wgcDownUntil=Date.now()+5000; }
        else if(++fails>=3){ mode='pw'; fails=0; }
        else throw e;
      }
    }
    if(!got){
      b=await grab('/frame.jpg?t='+Date.now());
      mode='pw'; srcName='PW';
      // Periodically look for the capturer again, but not while the back-off
      // says it is known to be down - each attempt costs ~2 s to fail.
      if(++probe>=25 && Date.now()>=wgcDownUntil){ probe=0;
        try{ const b2=await grab('http://127.0.0.1:8778/frame.jpg?t='+Date.now(),frameSeq);
             mode='wgc'; fails=0; srcName='WGC'; capturerUp=true; wgcDownUntil=0; if(b2!==null) b=b2; }catch(e){}
      }
    }
    // The FLAG_SECURE verdict can arrive while this frame is in flight - /rot is
    // polled on its own timer - so the blob is dropped rather than painted
    // behind the veil. Re-enter slowly; the /rot poll is what lifts the veil.
    if(!secureEl.hidden){ setTimeout(tick,400); return; }
    // b===null means 304: the screen has not changed, so leave the decoded frame
    // on screen rather than re-decoding the same bytes. Only a genuine new frame
    // is counted and painted, so the fps readout is frames actually shown.
    if(b){
      gotFrame=true;
      const u=URL.createObjectURL(b);
      img.onload=()=>{ if(prev) URL.revokeObjectURL(prev); prev=u;
                             dim.textContent=img.naturalWidth+'x'+img.naturalHeight;
                             layoutNav(); };
      img.src=u;
      n++;
    }
    setStatus('live','live');
    srcEl.textContent=srcName;
    const el=(performance.now()-t0)/1000;
    if(el>=1){ fps.textContent=(n/el).toFixed(0)+' fps'; n=0; t0=performance.now(); }
    live=true;
    showNoEmulator(false);
  }catch(e){
    // "no emulator running" is a normal state - the AVD can be stopped from
    // the toolbar - so it is reported as such rather than as a lost connection.
    // Otherwise the panel reads "reconnecting" while the server is perfectly
    // healthy, which points the reader at the wrong problem.
    const noEmu=/no emulator/i.test(e&&e.message?e.message:String(e));
    setStatus(noEmu?'no emulator running':'reconnecting... ('+e+')',noEmu?'idle':'error');
    if(noEmu) showNoEmulator(true);
  }
  // Self-paced. A fixed 80 ms delay capped the mirror at ~12 fps even though the
  // capturer answers in ~15 ms, so every frame the eye saw was up to 80 ms stale
  // on top of its own age -- the dominant lag once the input path was fixed.
  // Let the capture rate be the only limit; the floor only stops a fast error
  // response from spinning the loop, and a dead source backs off to 80 ms.
  // Back off while the screen is static. Hammering the capturer ~120x/s to chase
  // frames that do not exist starves it: a sustained motion test dropped the
  // capture rate to ~4 fps, because every poll is a new TCP connection against
  // the capturer's listener. Polling flat out only pays off *while frames are
  // actually arriving*, so an idle screen backs off and any real frame drops
  // straight back to the fast floor.
  const spent=performance.now()-tReq;
  if(live&&gotFrame) still=0; else still=Math.min(still+1,4);
  const gap=still<4?FRAME_MIN_GAP:FRAME_IDLE_GAP*Math.pow(2,still-3);
  setTimeout(tick, live?Math.max(0,gap-spent):80);
}
// The loop is started further down, once the initial /rot has reported whether
// the capturer is up.

// --- input forwarding: raw pointer streaming -> emulator console (multi-touch) ---
// The mirror forwards *actual* pointer motion to the guest instead of classifying
// gestures. Anything Android understands — tap, touch & hold, drag & drop, swipe,
// fling, two-finger pinch/spread, two-finger pan, edge (gesture-nav) swipes — then
// behaves exactly as it does on the real emulator, because the guest frameworks
// interpret the raw touches itself. Multi-touch is injected through the emulator
// console as MT protocol B events (adb's `input` command is single-pointer only).
let GW=1080,GH=2280;
const inpEl=document.getElementById('inp');
function note(msg){ inpEl.textContent=msg; }
// Adopt "WxH:R" from /rot so a freshly loaded page starts with the right size and
// with its keys already rotated to match the guest's current orientation.
function adoptRot(s){
  // "WxH:R" and optionally "WxH:R:C", where C is the capturer's state (1 up,
  // 0 down), and then "WxH:R:C:P", where P is 1 while the mirror is honouring
  // FLAG_SECURE and the window in front sets it. Split on ':' rather than one
  // big regex so the parts stay optional.
  const parts=String(s).split(':');
  const wh=(parts[0]||'').match(/(\d+)x(\d+)/);
  if(!wh) return;
  GW=+wh[1]; GH=+wh[2];
  if(parts[1]!==undefined) ROT=(+parts[1])%4;
  if(parts[2]!==undefined) capturerUp=(+parts[2])===1;
  if(parts[3]!==undefined) setProtected(parts[3]==='1');
}
// Rotation state, 0..3, pushed by the server and read back from /rot. Declared
// up here with the other bindings because layoutNav() is called synchronously
// below, before a `let` further down would initialise - which threw "Cannot
// access 'ROT' before initialization" and left every key unlaid out.
let ROT=0;

// Reserve room on whichever edge the soft-key bar rotates onto. Driven purely by
// the rotation index, never by a measurement, so it cannot feed back into the
// layout: #stage's outer box is fixed by flex:1 and its padding is inside it.
function reserveForRotation(){
  const bh=parseFloat(getComputedStyle(document.getElementById('wrap')).getPropertyValue('--barh'))||38;
  stage.style.paddingTop='0px';stage.style.paddingRight='0px';
  stage.style.paddingBottom='0px';stage.style.paddingLeft='0px';
  // The bar hangs off the portrait bottom of #keylayer; rotating the layer moves
  // that edge to: 0->bottom, 90cw->left, 180->top, 270->right.
  const side=['paddingBottom','paddingLeft','paddingTop','paddingRight'][ROT%4];
  stage.style[side]=bh+'px';
}

// The emulator's device skin rounds the display's bottom two corners, and the
// capture carries that arc with it: a light curve at each bottom corner of a
// screen that is otherwise a hard-edged rectangle. CSS cannot add pixels back,
// so each corner is covered with the frame's *own* content taken from one patch
// height above the arc. Copying real pixels is what makes the patch invisible -
// a flat colour guessed from the frame would show as a dot the moment the bottom
// of the screen is not uniformly dark.
//
// The frame is drawn at its displayed size times devicePixelRatio, so a source
// position in CSS px becomes -position*dpr in canvas px and the patch is 1:1
// with what #m paints underneath it. The size comes from the stylesheet, so one
// number (--sqpx) governs both the box and the sampling.
function patchCorners(){
  const iw=img.naturalWidth, ih=img.naturalHeight;
  const dpr=window.devicePixelRatio||1;
  const dw=parseFloat(stage.style.getPropertyValue('--imw'))||0;
  const dh=parseFloat(stage.style.getPropertyValue('--imh'))||0;
  for(const [cv,right] of [[sqL,0],[sqR,1]]){
    const sq=cv.getBoundingClientRect().width;    // --sqpx, in CSS px
    if(sq<1) continue;
    const px=Math.round(sq*dpr);
    if(cv.width!==px){ cv.width=px; cv.height=px; }
    const g=cv.getContext('2d');
    g.clearRect(0,0,px,px);
    if(!iw||!dw||!dh) continue;                   // no frame: leave the corner empty
    const x=(right?dw-2*sq:sq)*dpr;               // one patch width inwards from that edge
    const y=(dh-2*sq)*dpr;                        // one patch height above the bottom edge
    g.drawImage(img,-x,-y,dw*dpr,dh*dpr);
  }
}

function layoutNav(){
    const r=img.getBoundingClientRect();
    const iw=img.naturalWidth||GW, ih=img.naturalHeight||GH;
    const s=Math.min(r.width/iw,r.height/ih)||1;
    const dw=iw*s, dh=ih*s;
    const ox=r.left+(r.width-dw)/2, oy=r.top+(r.height-dh)/2;   // displayed screen, viewport
    const sg=stage.getBoundingClientRect();
    stage.style.setProperty('--imx',(ox-sg.left)+'px');
    stage.style.setProperty('--imw',dw+'px');
    stage.style.setProperty('--imy',(oy-sg.top)+'px');
    stage.style.setProperty('--imh',dh+'px');
    // Size #keylayer to the *portrait* equivalent of the displayed screen and
    // centre it on that screen, then rotate it. A rotated key layer lines the
    // nav bar and the side keys up with the rotated display exactly.
    const kr=(ROT%4)*90;
    const landscape=(kr===90||kr===270);
    const pw=landscape?dh:dw, ph=landscape?dw:dh;
    const cx=ox+dw/2-sg.left, cy=oy+dh/2-sg.top;
    kl.style.setProperty('--kx',(cx-pw/2)+'px');
    kl.style.setProperty('--ky',(cy-ph/2)+'px');
    kl.style.setProperty('--kw',pw+'px');
    kl.style.setProperty('--kh',ph+'px');
    kl.style.setProperty('--kr',kr+'deg');
    // The help popover is anchored to the top-right of the page and has to
    // clear the toolbar, whose height differs between the normal and the
    // compact layout. Measure it rather than hard-coding a gap.
    const bh=document.getElementById('bar').getBoundingClientRect().height;
    if(bh>0) document.getElementById('wrap').style.setProperty('--barpop',(bh+6)+'px');
    patchCorners();      // the patch source offset depends on the displayed scale
    }

// The first poll waits for the server's view of the capturer. A refused
// connection to a dead local port takes ~2 s to fail on this machine, so
// starting the frame loop before knowing whether the capturer is up would
// spend two seconds on a dead port before the no-emulator notice could
// appear. /rot answers in ~60 ms and says whether the capturer is running.
const rotReady = fetch('/rot',{cache:'no-store'}).then(r=>r.text()).then(s=>{
  adoptRot(s); reserveForRotation(); layoutNav();
}).catch(()=>{ reserveForRotation(); layoutNav(); });
layoutNav();
rotReady.then(()=>tick());

// Watch for the guest turning without the mirror's help - the emulator's own
// rotate shortcut, or an `adb shell wm user-rotation` run elsewhere. The server
// reconciles its own window and capturer; the page only has to notice the new
// orientation so GW/GH (which drive every client->guest coordinate mapping) and
// the key layer are re-derived. Without this the size and orientation were read
// exactly once at load, and an external rotation left taps mapped to the wrong
// guest pixel with the keys on the wrong edges.
let lastSeenRot=ROT, lastSeenW=GW, lastSeenH=GH;
setInterval(()=>{
  fetch('/rot',{cache:'no-store'}).then(r=>r.text()).then(s=>{
    const before=ROT, bw=GW, bh2=GH;
    adoptRot(s);
    if(ROT!==before||GW!==bw||GH!==bh2){ liftAll(); reserveForRotation(); layoutNav(); }
  }).catch(()=>{});
},1500);

const pts=new Map();          // pointerId -> [x,y] in guest px
let inflight=false,dirty=false;
function flush(){
  const p=[...pts].map(([id,v])=>id+':'+v[0]+':'+v[1]).join(',');
  if(inflight){ dirty=true; return; }
  inflight=true;
  fetch('/touch?p='+p,{cache:'no-store'}).then(r=>{
    inflight=false;
    if(!r.ok) note('touch unavailable');
    else if(dirty){ dirty=false; flush(); }
  }).catch(()=>{ inflight=false; note('touch unavailable'); });
}
function setPt(id,x,y){ pts.set(id,[Math.round(x),Math.round(y)]); flush(); }
function delPt(id){ if(pts.delete(id)) flush(); }
function liftAll(){ if(pts.size){ pts.clear(); flush(); } }
// Keepalive while any finger is down. A press & hold emits no move events, so
// without this the server's staleness reaper would read the silence as a dead
// client and lift the contact mid-gesture.
setInterval(()=>{ if(pts.size) flush(); },700);
const clamp=(v,a,b)=>v<a?a:v>b?b:v;

// Keep the soft keys centred on 25/50/75% of the *displayed* guest screen. The
// image is object-fit:contain, so the window width and the screen width differ
// whenever there are side letterboxes; anchoring to the window would slide the
// keys off the guest's own nav positions exactly when that happens. Same
// contain maths as gp(), exported to CSS as the letterbox offset (--imx), the
// displayed width (--imw) and the displayed height (--imh). The keys now sit
// inside the rotating #keylayer (see layoutNav above) so they follow the display
// orientation; each element gets the values relative to its own box.
// Re-measure whenever the settled layout changes. A ResizeObserver is used rather
// than a resize listener with rAF retries: the stage's height is itself a
// consequence of the bar's height, so the correct value is only known once the
// box has stopped changing. Fixed-delay retries settle for one or two frames and
// then stop, leaving the bar pinned to the previous geometry - measured as a
// constant 15.2 px offset at some panel sizes. Observing the box itself means the
// last measurement is the one that matches what is on screen. layoutNav() only
// writes custom properties, so observing stage and img cannot loop.
if(window.ResizeObserver){
  const ro=new ResizeObserver(()=>layoutNav());
  ro.observe(stage); ro.observe(img);
}
window.addEventListener('resize',layoutNav);

// map a client point inside the (object-fit:contain) image to guest px
function gp(e){
  const r=img.getBoundingClientRect();
  const s=Math.min(r.width/(img.naturalWidth||GW),r.height/(img.naturalHeight||GH))||1;
  const dw=(img.naturalWidth||GW)*s,dh=(img.naturalHeight||GH)*s;
  const ox=r.left+(r.width-dw)/2,oy=r.top+(r.height-dh)/2;
  const fx=Math.min(Math.max((e.clientX-ox)/dw,0),1);
  const fy=Math.min(Math.max((e.clientY-oy)/dh,0),1);
  return [Math.round(fx*GW),Math.round(fy*GH)];
}

const pointers=new Map();     // pointerId -> {start,anchor,last,ctrl,right,dragging,holdTimer}
// Right button = the emulator's "drag" (touch & hold, then move). The touch-down
// is injected a moment after the press so a quick right-click stays a pure Back
// (Back + a stray tap would otherwise both fire).
const DRAG_HOLD_MS=140, DRAG_SLOP=10;   // slop in guest px
img.addEventListener('pointerdown',e=>{
  if(e.button===1){ e.preventDefault(); liftAll(); nav('home'); return; }  // middle-click = Home
  if(e.button!==0 && e.button!==2) return;
  e.preventDefault(); img.focus();
  try{ img.setPointerCapture(e.pointerId); }catch(_){}
  const p=gp(e);
  const st={start:p,anchor:p,last:p,ctrl:e.ctrlKey,right:e.button===2,dragging:false};
  pointers.set(e.pointerId,st);
  if(st.right){
    const id=e.pointerId;
    st.holdTimer=setTimeout(()=>{ st.dragging=true; setPt(id,p[0],p[1]); },DRAG_HOLD_MS);
    return;
  }
  if(e.ctrlKey){
    // emulator pinch model: cursor is finger 1, reflected across the anchor is finger 2
    setPt(e.pointerId+'a',p[0],p[1]);
    setPt(e.pointerId+'b',p[0],p[1]);
  } else {
    setPt(e.pointerId,p[0],p[1]);
  }
});
img.addEventListener('pointermove',e=>{
  const st=pointers.get(e.pointerId); if(!st) return;
  const p=gp(e); st.last=p;
  if(st.right){
    if(!st.dragging){                     // moved before the hold elapsed -> drag now
      if(Math.abs(p[0]-st.start[0])+Math.abs(p[1]-st.start[1])<DRAG_SLOP) return;
      clearTimeout(st.holdTimer); st.dragging=true;
      setPt(e.pointerId,st.start[0],st.start[1]);
    }
    setPt(e.pointerId,p[0],p[1]);
    return;
  }
  if(st.ctrl){
    setPt(e.pointerId+'a',p[0],p[1]);
    setPt(e.pointerId+'b',2*st.anchor[0]-p[0],2*st.anchor[1]-p[1]);
  } else {
    setPt(e.pointerId,p[0],p[1]);
  }
});
img.addEventListener('pointerup',e=>{
  const st=pointers.get(e.pointerId); if(!st) return;
  pointers.delete(e.pointerId);
  if(st.right){
    clearTimeout(st.holdTimer);
    if(st.dragging){ delPt(e.pointerId); return; }   // right-hold / right-drag
    nav('back'); return;                             // quick right-click = Back
  }
  if(st.ctrl){ delPt(e.pointerId+'a'); delPt(e.pointerId+'b'); return; }
  const p=gp(e);
  if(st.last[0]!==p[0]||st.last[1]!==p[1]) setPt(e.pointerId,p[0],p[1]);
  delPt(e.pointerId);
});
img.addEventListener('pointercancel',e=>{
  const st=pointers.get(e.pointerId); if(!st) return;
  pointers.delete(e.pointerId);
  if(st.right){ clearTimeout(st.holdTimer); if(st.dragging) delPt(e.pointerId); return; }
  if(st.ctrl){ delPt(e.pointerId+'a'); delPt(e.pointerId+'b'); }
  else delPt(e.pointerId);
});
img.addEventListener('contextmenu',e=>e.preventDefault());
img.addEventListener('dragstart',e=>e.preventDefault());
img.addEventListener('mousedown',e=>{ if(e.button===0) e.preventDefault(); });

// scrolling: wheel notches are accumulated and replayed through /input?swipe,
// the one scroll path verified to register with the guest. Driving it from raw
// /touch does reach the kernel, but a wheel notch is a single ~130 px jump and
// Android classifies that as a tap, so the list never moves.
//
// Direction: the wheel becomes a finger drag, so its sign is flipped to feel
// right. "Natural" (the default) sends wheel-down as a finger moving UP,
// carrying the content up and advancing you further down the page, matching
// touch and macOS trackpads. "Classic" is physical-mouse behaviour:
// wheel-down drags the finger down and reveals earlier content.
let naturalScroll=true;
try{ const v=localStorage.getItem('mirror.scrollNatural'); if(v!==null) naturalScroll=(v!=='0'); }catch(_){}
const sdir=document.getElementById('sdir'), sdirLbl=sdir.querySelector('.lbl');
function paintSdir(){
  // The word lives in its own span so the compact layout can drop it and leave
  // the bare arrow - in a 320 px panel the glyph plus a title is enough, and the
  // word cost more width than any other control in the strip.
  sdirLbl.textContent=naturalScroll?'Natural':'Classic';
  sdir.title=(naturalScroll
    ? 'Wheel down reveals content further down (natural)'
    : 'Wheel down reveals earlier content (classic)')+' - click to toggle';
  sdir.setAttribute('aria-label','Scroll direction: '+(naturalScroll?'natural':'classic'));
}
sdir.addEventListener('click',()=>{
  naturalScroll=!naturalScroll;
  try{ localStorage.setItem('mirror.scrollNatural',naturalScroll?'1':'0'); }catch(_){}
  paintSdir(); liftAll();
});
paintSdir();

  // A wheel burst becomes a real drag under the cursor. The anchor is re-taken
  // from the cursor on every flush instead of being carried forward: a carried
  // anchor walks to the screen edge, and once it is clamped against the edge the
  // remaining notches collapse into a zero-length drag that never scrolls.
  const WHEEL_MARGIN=Math.round(GH*0.15);   // keep the drag clear of the edges
  let wheelAcc=[0,0], wheelTimer=0;
  // The drag is replayed here instead of being handed to the server's
  // /input?swipe. That endpoint runs the gesture inline on a single-threaded
  // accept loop, so a 660 ms scroll occupied the loop for its whole duration and
  // every /touch frame queued behind it -- input arriving mid-scroll waited out
  // the remainder. Replaying the interpolated steps through the fast /touch path
  // keeps the scroll fluid and leaves the loop free.
  let wheelAnimating=false, wheelPending=false;
  function wheelAnimate(x1,y1,x2,y2,ms){
    if(wheelAnimating){ wheelPending=true; return; }   // replay the remainder next
    wheelAnimating=true;
    const id='ws';
    setPt(id,x1,y1);
    const t0=performance.now();
    const frame=()=>{
      // Time-based rather than step-based: a dropped frame shortens the run
      // instead of stretching the gesture, so the guest always sees the
      // intended total distance.
      const f=Math.min(1,(performance.now()-t0)/ms);
      if(f>=1){
        setPt(id,x2,y2); delPt(id);
        wheelAnimating=false;
        if(wheelPending){ wheelPending=false; wheelFlush(); }
        return;
      }
      setPt(id, Math.round(x1+(x2-x1)*f), Math.round(y1+(y2-y1)*f));
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }
  function wheelFlush(){
    const dx=wheelAcc[0], dy=wheelAcc[1];
    wheelAcc=[0,0];
    const dist=Math.hypot(dx,dy);
    if(dist<4) return;
    const [ax,ay]=wheelLast;
    // Centre the drag on the cursor, then shift the start point back inside the
    // margins so the whole delta is delivered instead of being clipped.
    let x1=ax-dx/2, y1=ay-dy/2, x2=ax+dx/2, y2=ay+dy/2;
    const lo=Math.min(WHEEL_MARGIN,GW-1-WHEEL_MARGIN);
    const hi=Math.max(WHEEL_MARGIN,GW-1-WHEEL_MARGIN);
    const loY=Math.min(WHEEL_MARGIN,GH-1-WHEEL_MARGIN);
    const hiY=Math.max(WHEEL_MARGIN,GH-1-WHEEL_MARGIN);
    const span=Math.max(0,(GW-1)-2*lo), spanY=Math.max(0,(GH-1)-2*loY);
    if(Math.abs(dx)>span){ x1=clamp(x1,lo,hi); x2=clamp(x2,lo,hi); }
    if(Math.abs(dy)>spanY){ y1=clamp(y1,loY,hiY); y2=clamp(y2,loY,hiY); }
    x1=clamp(x1,0,GW-1); y1=clamp(y1,0,GH-1);
    x2=clamp(x2,0,GW-1); y2=clamp(y2,0,GH-1);
    // ~1 ms per px reads as a natural finger scroll; Android needs the gesture to
    // last long enough to be read as a drag rather than a flick.
    const ms=Math.round(Math.min(700,Math.max(140,Math.hypot(x2-x1,y2-y1)*1.0)));
    wheelAnimate(Math.round(x1),Math.round(y1),Math.round(x2),Math.round(y2),ms);
  }
  let wheelLast=[0,0];
  img.addEventListener('wheel',e=>{
    e.preventDefault();
    const [px,py]=gp(e);
    if(e.ctrlKey){ pinchWheel(px,py,e.deltaY); return; }
    const sgn=naturalScroll?-1:1;
    const k=1.1*sgn;
    wheelAcc[0]+=(e.shiftKey? e.deltaY : e.deltaX)*k;
    wheelAcc[1]+=(e.shiftKey? 0 : e.deltaY)*k;
    wheelLast=[px,py];
    clearTimeout(wheelTimer);
    wheelTimer=setTimeout(wheelFlush,90);   // coalesce a burst of notches into one scroll
  },{passive:false});

// Ctrl+wheel = pinch/spread around the cursor, like the emulator's Ctrl+drag
let pinchR=0,pinchTimer=0;
function pinchWheel(cx,cy,delta){
  const step=Math.max(6,Math.min(60,Math.abs(delta)));
  if(!pinchR){ pinchR=Math.round(GW*0.12); setPt('pa',cx-pinchR,cy); setPt('pb',cx+pinchR,cy); }
  pinchR=clamp(pinchR+(delta>0?-step:step),Math.round(GW*0.02),Math.round(GW*0.9));
  setPt('pa',cx-pinchR,cy); setPt('pb',cx+pinchR,cy);
  clearTimeout(pinchTimer);
  pinchTimer=setTimeout(()=>{ delPt('pa'); delPt('pb'); pinchR=0; },90);
}

// keys: nav + editing shortcuts; remaining printable keys are typed
function send(q){ return fetch('/input?'+q,{cache:'no-store'}).catch(()=>{}); }
function nav(a){ send('nav='+a); }

// --- hide / show the emulator window -----------------------------------------
// Hiding it for real (SW_HIDE) or minimizing it stops the capture dead: both
// take the window out of the DWM composition the frame comes from (measured:
// 0 frames in 3 s hidden, ~53 fps with the window merely parked outside the
// virtual screen). So the server parks it off-screen instead, which is out of
// sight and still mirroring. The state is read back from the server rather
// than kept here alone, because a reload - or a toggle from the VS Code
// command palette - changes it without this page doing anything.
const hideBtn=document.getElementById('hideemu');
let emuHidden=false;
function paintHide(){
  hideBtn.textContent=emuHidden?'Show':'Hide';
  hideBtn.setAttribute('aria-pressed',emuHidden?'true':'false');
  hideBtn.title=emuHidden?'Bring the emulator window back on screen'
                         :'Hide the emulator window - it stays off-screen and keeps mirroring';
}
async function syncHide(){
  try{
    const j=await (await fetch('/window?state=1',{cache:'no-store'})).json();
    if(j.state==='no-emulator'){ emuHidden=false; paintHide(); return; }
    emuHidden=!!j.hidden;
  }catch(e){ return; }              // server restarting: keep the last label
  paintHide();
}
hideBtn.addEventListener('click',async()=>{
  hideBtn.disabled=true;
  try{
    const j=await (await fetch('/window?hidden='+(emuHidden?'0':'1'),{cache:'no-store'})).json();
    if(!j.ok){
      // "no-emulator" is a normal state, not a failure worth shouting about.
      note(j.state==='no-emulator'?'no emulator window to '+(emuHidden?'show':'hide')
                                   :'cannot move the window: '+j.state);
      emuHidden=!!j.hidden;
    } else {
      emuHidden=!!j.hidden;
      note(emuHidden?'emulator window hidden - still mirroring'
                    :(j.front?'emulator window restored in front':'emulator window restored'));
    }
  }catch(e){ note('window toggle failed'); }
  finally{ paintHide(); hideBtn.disabled=false; }
});
paintHide();
syncHide();
setInterval(syncHide,2000);

// --- AVD picker -------------------------------------------------------------
// The AVD manager (avd.ps1) runs on its own port and is a separate origin, so
// these calls are cross-origin; it sends Access-Control-Allow-Origin: *.
const AVD_BASE='http://127.0.0.1:8779';
const avdSel=document.getElementById('avdsel'), avdGo=document.getElementById('avdgo'),
      avdState=document.getElementById('avdstate'), avdWord=avdState.querySelector('.txt');
// One button, not two. Start and Stop are mutually exclusive states of the same
// thing, so side-by-side buttons made the reader work out which one applied right
// now; a label stating the next action does that for them, and it keeps stating
// it through the ~40 s boot ("Booting…", still clickable to cancel).
let avdBusy=false, avdStatus='stopped';

async function avdFetch(path){
  const r=await fetch(AVD_BASE+path,{cache:'no-store'});
  if(!r.ok) throw new Error('HTTP '+r.status);
  return await r.json();
}

// Every path that changes avdBusy/avdStatus ends here, so the button label and
// the state dot can never contradict each other.
function paintAvd(){
  const running=avdStatus==='running', starting=avdStatus==='starting';
  const cls=avdStatus==='none'?'none':(running?'running':(starting?'starting':'stopped'));
  const word=avdBusy&&cls!=='none'?'busy':(cls==='none'?'no manager':cls);
  avdGo.textContent=starting?'Booting\u2026':(running?'Stop':'Start');
  avdGo.dataset.act=(running||starting)?'stop':'start';
  avdGo.disabled=avdBusy||avdStatus==='none';
  avdGo.title=cls==='none'?'The AVD manager is not responding'
    :starting?'Booting - click to stop it'
    :running?'Stop the running AVD':'Start the selected AVD';
  avdState.className='avdstate '+(avdBusy&&cls!=='none'?'busy':cls);
  avdWord.textContent=word;
  avdState.title='AVD: '+word;
}

// Refresh the dropdown and the state. The list is re-read every time rather
// than cached, so an AVD created or deleted elsewhere shows up.
async function refreshAvds(){
  try{
    const avdSt=await avdFetch('/avds');
    const want=avdSt.selected||avdSt.running||(avdSt.avds[0]&&avdSt.avds[0].name)||'';
    // Rebuild the options, keeping the current selection when it survives.
    const keep=avdSel.value||want;
    avdSel.innerHTML='';
    for(const a of avdSt.avds){
      const o=document.createElement('option');
      o.value=a.name;
      o.textContent=a.name+(a.api?' ('+a.api.replace('API ','api ')+')':'')+(a.running?' - running':'');
      avdSel.appendChild(o);
    }
    if(keep&&[...avdSel.options].some(o=>o.value===keep)) avdSel.value=keep;
    else if(want) avdSel.value=want;

    avdStatus=avdSt.status||'stopped';
    avdSel.disabled=avdBusy;
    avdSel.title='Select an AVD';
    paintAvd();
    return avdSt;
  }catch(e){
    // The manager is a separate process on its own port; when it is down the
    // picker can do nothing, and saying so beats leaving it looking usable.
    avdStatus='none'; avdSel.disabled=true; avdSel.title='The AVD manager is not responding';
    paintAvd();
    return null;
  }
}

// Selecting an AVD remembers it, so the mirror can start that one by itself
// next time. The server stores it; the page only mirrors the choice.
avdSel.addEventListener('change',()=>{
  fetch(AVD_BASE+'/avd/select?name='+encodeURIComponent(avdSel.value),{cache:'no-store'}).catch(()=>{});
});

// --- gesture help ------------------------------------------------------------
// The shortcuts used to live in a title attribute on the screen, where the hover
// tooltip covered the content it described. They now open from the "i" button in
// the top right of the toolbar.
const helpBtn=document.getElementById('helpbtn'), helpPop=document.getElementById('helppop');
function setHelp(open){
  helpPop.hidden=!open;
  helpBtn.setAttribute('aria-expanded',open?'true':'false');
}
helpBtn.addEventListener('click',e=>{ e.stopPropagation(); setHelp(helpPop.hidden); });
// Click away or press Escape to dismiss.
document.addEventListener('click',e=>{ if(!helpPop.hidden) setHelp(false); });
document.addEventListener('keydown',e=>{ if(e.key==='Escape') setHelp(false); });

avdGo.addEventListener('click',()=>{ if(avdGo.dataset.act==='stop') stopRunning(); else startSelected(); });

async function startSelected(){
  const name=avdSel.value; if(!name) return;
  avdBusy=true; paintAvd();
  try{
    await fetch(AVD_BASE+'/avd/start?name='+encodeURIComponent(name),{method:'POST',cache:'no-store'});
    note('starting '+name);
  }catch(e){ note('start failed'); }
  finally{ avdBusy=false; paintAvd(); }
  // The AVD takes ~40 s to boot. Poll until it is up rather than assuming.
  for(let i=0;i<80;i++){
    await new Promise(r=>setTimeout(r,1000));
    const avdSt=await refreshAvds();
    if(avdSt&&(avdSt.status==='running'||avdSt.status==='stopped')) break;
  }
  await refreshAvds();
}

async function stopRunning(){
  avdBusy=true; paintAvd();
  try{
    await fetch(AVD_BASE+'/avd/stop?force=0',{method:'POST',cache:'no-store'});
    note('stopping');
  }catch(e){ note('stop failed'); }
  finally{ avdBusy=false; paintAvd(); }
  // Graceful first. If the guest does not come down, ask before forcing it -
  // a force stop loses unsaved guest state, so it is never done silently.
  let gone=false;
  for(let i=0;i<40;i++){
    await new Promise(r=>setTimeout(r,500));
    const avdSt=await refreshAvds();
    if(avdSt&&avdSt.status==='stopped'){ gone=true; break; }
  }
  if(!gone){
    if(confirm('The emulator did not shut down gracefully.\n\nForce stop it now? Unsaved guest state will be lost.')){
      await fetch(AVD_BASE+'/avd/stop?force=1',{method:'POST',cache:'no-store'}).catch(()=>{});
      note('force stopped');
      for(let i=0;i<20;i++){
        await new Promise(r=>setTimeout(r,500));
        const avdSt=await refreshAvds();
        if(avdSt&&avdSt.status==='stopped') break;
      }
    }
  }
  await refreshAvds();
}

refreshAvds();
setInterval(refreshAvds,3000);

const KEYMAP={Enter:'KEYCODE_ENTER',Backspace:'KEYCODE_DEL',Escape:'KEYCODE_BACK',Tab:'KEYCODE_TAB',
  Delete:'KEYCODE_FORWARD_DEL',ArrowUp:'KEYCODE_DPAD_UP',ArrowDown:'KEYCODE_DPAD_DOWN',
  ArrowLeft:'KEYCODE_DPAD_LEFT',ArrowRight:'KEYCODE_DPAD_RIGHT',
  Home:'KEYCODE_MOVE_HOME',End:'KEYCODE_MOVE_END',PageUp:'KEYCODE_PAGE_UP',PageDown:'KEYCODE_PAGE_DOWN'};
const CTLMAP={'c':'KEYCODE_COPY','v':'KEYCODE_PASTE','x':'KEYCODE_CUT','a':'KEYCODE_SELECT_ALL',
  'z':'KEYCODE_UNDO','y':'KEYCODE_REDO'};
document.addEventListener('keydown',e=>{
  if(e.metaKey||e.altKey) return;
  if(e.ctrlKey){
    const k=CTLMAP[e.key.toLowerCase()];
    if(k){ e.preventDefault(); send('key='+k); }
    return;                                     // other chords left to the browser
  }
  if(KEYMAP[e.key]){ e.preventDefault(); send('key='+KEYMAP[e.key]); return; }
  if(e.key.length===1){ e.preventDefault(); send('text='+encodeURIComponent(e.key)); }
});
document.querySelectorAll('button[data-nav]').forEach(b=>{
  b.addEventListener('click',()=>{ nav(b.dataset.nav); img.focus(); });
});
// Rotation replies with the guest's new size, so the page can adopt it without a
// second request. GW/GH drive every client->guest coordinate mapping (gp, the
// pointer handlers, the pinch radius), so leaving them at the pre-rotation size
// would put every tap at the wrong guest pixel in landscape.
document.querySelectorAll('button[data-rot]').forEach(b=>{
  b.addEventListener('click',async()=>{
    b.disabled=true;
    try{
      const r=await fetch('/input?rot='+b.dataset.rot,{cache:'no-store'});
      const s=await r.text();
            adoptRot(s);                        // updates GW/GH and ROT
            reserveForRotation();               // move the bar reservation to the new edge
      note('rotated '+s);
    }catch(e){ note('rotate failed'); }
    finally{ b.disabled=false; liftAll(); layoutNav(); img.focus(); }
  });
});
window.addEventListener('blur',liftAll);
// If the tab is closed or reloaded mid-gesture the final lift never leaves the
// page; beacon it so the guest is not left holding a phantom finger.
window.addEventListener('pagehide',()=>{
  if(pts.size){ const p=[...pts].map(([id,v])=>id+':'+v[0]+':'+v[1]).join(',');
                navigator.sendBeacon('/touch?p='); }
});
document.addEventListener('visibilitychange',()=>{ if(document.hidden) liftAll(); });
document.addEventListener('visibilitychange',()=>{ if(document.hidden) liftAll(); });
</script></body></html>
'@

# The page calls the AVD manager cross-origin, so it has to be told the port the
# extension actually got for it (avd.ps1 prefers 8779 but moves when that port is
# held by something else). The literal in the page above is the default.
if ($AvdPort -ne 8779) {
  $html = $html.Replace("127.0.0.1:8779", "127.0.0.1:$AvdPort")
}

function Send-Bytes([System.Net.Sockets.NetworkStream]$s, [string]$status, [string]$contentType, [byte[]]$body) {
  # frame-ancestors lets the page be embedded; the CORS headers let it also be
  # *inlined* into a VS Code webview, whose origin is not 127.0.0.1 and so cannot
  # read loopback responses without them. The listener is bound to loopback
  # only, so the exposure is other local processes (and any web page the user
  # happens to visit that reads 127.0.0.1:8777) - never the network.
  #
  # `*` alone does NOT make the page framable everywhere: it matches only network
  # schemes (http, https, ws, wss), so a VS Code webview was refused with
  # "Framing 'http://127.0.0.1:8777/' violates the following Content Security
  # Policy directive: frame-ancestors *" - the embedded-browser tab came up black.
  # frame-ancestors is checked against every ancestor, and a desktop webview sits
  # inside two non-network documents: the webview itself (`vscode-webview:`) and
  # the workbench window (`vscode-file:`). Non-network schemes have to be listed
  # explicitly; `file:` covers a local harness page.
  $head = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nContent-Security-Policy: frame-ancestors * vscode-webview: vscode-file: file:`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Headers: *`r`nConnection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $s.Write($hb, 0, $hb.Length)
  if ($body -and $body.Length -gt 0) { $s.Write($body, 0, $body.Length) }
  $s.Flush()
}

# --- server ------------------------------------------------------------------
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$rescue = -not $NoRescue
Write-Output "MIRROR listening on http://127.0.0.1:$Port/  hwnd=$hwnd rescue=$rescue"
Write-Output "guest $gsize  touch: emulator console 127.0.0.1:$script:ConsolePort"
[void](Send-Console 'ping')
if ($script:Console) { Write-Output 'emulator console connected - multi-touch gestures enabled' }
else { Write-Output 'WARNING: emulator console unreachable - touch input will fail (needs a running AVD)' }

# Seed the orientation the mirror currently believes in, so the reconciler in the
# /rot handler only fires on a *change*.
$script:lastRot = Get-GuestRotation

while ($true) {
  # The emulator may have been stopped and restarted. Do NOT exit: the AVD
  # controls exist precisely so an emulator can be cycled, and the mirror
  # quitting on emulator exit left the page permanently on "reconnecting".
  # The target is re-acquired from the request path instead.
  $tcp = $listener.AcceptTcpClient()
    try {
      $tcp.ReceiveTimeout = 5000
      $stream = $tcp.GetStream()
    # read request headers
    $buf = New-Object byte[] 8192
    $acc = ''; $total = 0
    while (-not $acc.Contains("`r`n`r`n") -and $total -lt 8192) {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $acc += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n); $total += $n
    }
    $requestLine = ($acc -split "`r`n")[0]
    $path = ($requestLine -split ' ')[1]
    if (-not $path) { $path = '/' }

    # Pick up an emulator that was replaced since the last request. Done here,
    # once per request, so every path benefits: the frame needs the new window
    # handle and touch needs the new console port.
    $emuUp = Update-EmulatorTarget
    if ($emuUp) { Ensure-Capturer }

    if ($path -like '/frame.jpg*') {
      if ($emuUp) {
        $jpeg = [EmuMirrorWin]::Capture($script:EmuHwnd, $rescue, $Quality, $GSW, $GSH)
        if ($jpeg) { Send-Bytes $stream '200 OK' 'image/jpeg' $jpeg }
        else       { Send-Bytes $stream '503 Service Unavailable' 'text/plain' ([byte[]][char[]]'capture failed') }
      }
      else {
        # No emulator: say so plainly rather than serving a broken image, and
        # let the page show it instead of "reconnecting".
        Send-Bytes $stream '503 Service Unavailable' 'text/plain' ([byte[]][char[]]'no emulator running')
      }
    }
    elseif ($path -eq '/' -or $path -like '/index*' -or (($path -split '\?')[0]) -eq '/') {
          # The bare path is compared with any query string stripped: the extension
          # cache-busts the page URL (?t=...) so a stale copy cannot pin old CSS in
          # the webview after mirror.ps1 changes.
          Send-Bytes $stream '200 OK' 'text/html; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($html))
        }
    elseif ($path -like '/touch*') {
      # /touch?p=id:x:y,id:x:y  -- raw pointer state in guest px; empty p lifts all
          Reap-StaleSlots
          $p = Get-QueryParams $path
          $spec = ''
          if ($p.ContainsKey('p')) { $spec = $p['p'] }
          if ($spec) {
            if (Send-TouchState $spec) { Send-Bytes $stream '200 OK' 'text/plain' ([byte[]][char[]]'ok') }
            else                       { Send-Bytes $stream '503 Service Unavailable' 'text/plain' ([byte[]][char[]]'touch unavailable') }
          } else {
            # A lift-all is also the recovery path for wedged contacts, so it sweeps
            # the whole slot space rather than only this script's own bookkeeping.
            Reset-Touch | Out-Null
            Send-Bytes $stream '200 OK' 'text/plain' ([byte[]][char[]]'ok')
          }
        }
    elseif ($path -like '/input*') {
      # /input?tap=x,y | press=x,y[,ms] | swipe=x1,y1,x2,y2,ms
      #        | pinch=cx,cy,r1,r2,ms | recents=x,y[,mid]
      #        | nav=home|back|recents|volup|voldown|power|menu | key=KEYCODE | text=chars
      #        | rot=0..3  -> rotates the guest and replies with the new WxH
      $p = Get-QueryParams $path
      $err = ''
            $rotBody = ''            # set only by rot=, to reply with the new size
      try {
        if ($p.ContainsKey('tap')) {
          $a = $p['tap'] -split ','
          Invoke-TouchTap -X ([int]$a[0]) -Y ([int]$a[1])
        }
        elseif ($p.ContainsKey('press')) {                       # touch & hold
          $a = $p['press'] -split ','
          $ms = if ($a.Count -ge 3) { [int]$a[2] } else { 700 }
          Invoke-TouchTap -X ([int]$a[0]) -Y ([int]$a[1]) -Hold $ms
        }
        elseif ($p.ContainsKey('swipe')) {
          $a = $p['swipe'] -split ','
          Invoke-TouchSwipe -X1 ([int]$a[0]) -Y1 ([int]$a[1]) -X2 ([int]$a[2]) -Y2 ([int]$a[3]) -Ms ([int]$a[4])
        }
        elseif ($p.ContainsKey('pinch')) {                       # pinch/spread around a centre
          $a = $p['pinch'] -split ','
          $cx = [int]$a[0]; $cy = [int]$a[1]; $r1 = [int]$a[2]; $r2 = [int]$a[3]; $ms = [int]$a[4]
          Invoke-TouchPinch -X1 ($cx - $r1) -Y1 $cy -X2 ($cx + $r1) -Y2 $cy -EX1 ($cx - $r2) -EY1 $cy -EX2 ($cx + $r2) -EY2 $cy -Ms $ms
        }
        elseif ($p.ContainsKey('recents')) {                     # bottom-edge swipe up + hold
          $a = $p['recents'] -split ','
          $x = [int]$a[0]
          $y = if ($a.Count -ge 2) { [int]$a[1] } else { $GSH - 4 }
          $mid = if ($a.Count -ge 3) { [int]$a[2] } else { [int]($GSH * 0.6) }
          $rStart = [datetime]::UtcNow
          [void](Send-TouchState "1:${x}:${y}")
          Wait-ForDeadline $rStart.AddMilliseconds(40)
          [void](Send-TouchState "1:${x}:${mid}")
          Wait-ForDeadline $rStart.AddMilliseconds(740)
          [void](Send-TouchState '')
        }
        elseif ($p.ContainsKey('nav')) {
          if (-not (Invoke-NavKey $p['nav'])) { $err = "unknown nav action '$($p['nav'])'" }
        }
        elseif ($p.ContainsKey('key')) {
          [void](Invoke-Adb -Arguments @('shell', 'input', 'keyevent', $p['key']))
        }
        elseif ($p.ContainsKey('text')) {
          Send-Text $p['text']
        }
                elseif ($p.ContainsKey('rot')) {
                  # Rotate and report the new guest size *and* orientation, so the page
                  # can remap coordinates and spin its keys in one round trip.
                  $reply = Invoke-Rotate -Rotation ([int]($p['rot']))
                  $parts = $reply -split ':'
                  $newSize = $parts[0]
                  $GSW = [int](($newSize -split 'x')[0])
                  $GSH = [int](($newSize -split 'x')[1])
                  $err = ''
                  $cap = 0
                  if (Get-Process wgccap -ErrorAction SilentlyContinue) { $cap = 1 }
                  $blank = 0
                  if (Test-FlagSecure) { $blank = 1 }
                  $rotBody = $newSize + ':' + $parts[1] + ':' + $cap + ':' + $blank
                }
                else { $err = 'unknown input cmd' }
              } catch { $err = $_.Exception.Message }
              if ($err) { Send-Bytes $stream '500 Server Error' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes($err)) }
              elseif ($rotBody) { Send-Bytes $stream '200 OK' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes($rotBody)) }
              else      { Send-Bytes $stream '200 OK' 'text/plain' ([byte[]][char[]]'ok') }
    }
    elseif ($path -like '/rot*') {
      # Current size and orientation as "WxH:R", so a freshly loaded page (or one
      # reloaded after the guest was rotated elsewhere) places its keys correctly.
          # Reconcile first: the page polls this, so it is where an orientation change
          # the mirror did not make - the emulator's own rotate shortcut, or an
          # `adb shell wm user-rotation` elsewhere - gets picked up. Without it the
          # window kept its old aspect and wgccap kept a portrait crop, so a landscape
          # guest was shown squeezed with the keys on the wrong edges.
          $rot = Get-GuestRotation
          if ($rot -ne $script:lastRot) { $reply = Sync-AfterRotation }
          else { $reply = (Get-GuestSize) + ':' + $rot }
          # Report whether the capturer is up. The page needs this because a
          # refused connection to a dead local port takes ~2 s to fail here, and
          # polling a capturer that is not there would stall the frame loop and
          # delay the no-emulator notice by seconds.
          $cap = 0
          if (Get-Process wgccap -ErrorAction SilentlyContinue) { $cap = 1 }
          # Fifth field: 1 while the mirror is honouring FLAG_SECURE and the
          # window in front has it set. The page blanks itself on it - the frames
          # come straight from the capturer, so this verdict is the only thing
          # that can stop them being shown.
          $blank = 0
          if (Test-FlagSecure) { $blank = 1 }
          Send-Bytes $stream '200 OK' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes($reply + ':' + $cap + ':' + $blank))
        }
    elseif ($path -like '/secure*') {
      # /secure?honour=1|0|toggle -> the policy; no parameter only reports.
      # The extension owns the setting (avdMirror.honourFlagSecure) and pushes it
      # here, so the page, the panel and the browser tab all obey one switch.
      $p = Get-QueryParams $path
      if ($p.ContainsKey('honour')) {
        $v = $p['honour']
        if ($v -eq 'toggle') { $script:HonourSecure = -not $script:HonourSecure }
        else { $script:HonourSecure = ($v -ne '0' -and $v -ne 'false') }
        # Re-measure at once: turning it on must blank the mirror now, not on
        # whatever the next cached poll would have been.
        $script:SecureAt = [datetime]::MinValue
      }
      $sec = Test-FlagSecure
      $h = if ($script:HonourSecure) { 'true' } else { 'false' }
      $s = if ($sec) { 'true' } else { 'false' }
      $body = '{"honour":' + $h + ',"secure":' + $s + '}'
      Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body))
    }
    elseif ($path -like '/build*') {
      # Which script is actually running. The extension hashes the copy it ships
      # and compares; a mismatch means this process predates the extension and
      # has to be replaced (see startServer()).
      $body = '{"build":"' + $script:BuildId + '","pid":' + $PID + '}'
      Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body))
    }
    elseif ($path -like '/window*') {
      # /window?hidden=1|0|toggle -> park the emulator window just outside the
      # virtual screen (out of sight, still captured) or put it back;
      # /window?state=1 only reports which of the two it currently is.
      # Lives here rather than in the capturer because the page is served from
      # this port and the PrintWindow fallback needs the same control.
      $p = Get-QueryParams $path
      $state = ''
      $ok = $true
      try {
        if ($p.ContainsKey('state')) {
          # Asking for the state also re-parks a window the emulator put back on
          # screen: this poll is the only thing running when nothing is capturing.
          [void][EmuMirrorWin]::EnforceParked($script:EmuHwnd)
          $state = [EmuMirrorWin]::HiddenState($script:EmuHwnd)
        }
        else {
          $hide = $false
          if ($p.ContainsKey('hidden')) {
            $v = $p['hidden']
            if ($v -eq 'toggle') { $hide = ([EmuMirrorWin]::HiddenState($script:EmuHwnd) -ne 'hidden') }
            else { $hide = ($v -ne '0' -and $v -ne 'false') }
          }
          $state = [EmuMirrorWin]::SetHidden($script:EmuHwnd, $hide)
          if ($state.StartsWith('failed')) { $ok = $false }
        }
      } catch { $state = 'failed:' + $_.Exception.Message; $ok = $false }
      if ($state -eq 'no-emulator') { $ok = $false }
      $body = '{"ok":' + $(if ($ok) { 'true' } else { 'false' }) + ',"state":"' + $state +
              '","hidden":' + $(if ($state -eq 'hidden') { 'true' } else { 'false' }) +
              '","front":' + $(if ($state -eq 'shown' -and [EmuMirrorWin]::lastFront) { 'true' } else { 'false' }) + '}'
      Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body))
    }
    elseif ($path -like '/controls*') {
      # /controls -> open (or raise) the emulator's Extended Controls dialog.
      # No console command exists for it, so this drives the emulator's own
      # toolbar through UI Automation - see Show-ExtendedControls.
      $state = Show-ExtendedControls
      $ok = -not ($state.StartsWith('failed') -or $state -eq 'no-emulator' -or $state -eq 'no-toolbar')
      $body = '{"ok":' + $(if ($ok) { 'true' } else { 'false' }) + ',"state":"' + $state +
              '","front":' + $(if ($script:ControlsFront) { 'true' } else { 'false' }) + '}'
      Send-Bytes $stream '200 OK' 'application/json' ([System.Text.Encoding]::UTF8.GetBytes($body))
    }
    elseif ($path -like '/gsize*') {
      # guest screen size, used for client -> guest coordinate mapping
      $gsize = Get-GuestSize
      $GSW = [int](($gsize -split 'x')[0])
      $GSH = [int](($gsize -split 'x')[1])
      Send-Bytes $stream '200 OK' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes($gsize))
    }
    else {
      Send-Bytes $stream '404 Not Found' 'text/plain' ([byte[]][char[]]'not found')
    }
  }
  catch { }
  finally { $tcp.Close() }
}
