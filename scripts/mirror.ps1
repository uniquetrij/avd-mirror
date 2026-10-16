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
  the virtual screen (invisible, still rendering). If the user Alt-Tabs / clicks
  the taskbar entry for that off-screen window, it snaps back to its last
  on-screen position.

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
  [switch]$NoRescue            # do not auto-restore/park a minimized emulator
)

$ErrorActionPreference = 'Stop'

# --- locate the emulator window ---------------------------------------------
$qemu = Get-Process qemu-system-x86_64 -ErrorAction Stop |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
if (-not $qemu) { throw 'No running Android emulator window (qemu-system-x86_64) found.' }
$hwnd = $qemu.MainWindowHandle

# --- adb + emulator console --------------------------------------------------
# Touch is injected through the emulator console ("event send") instead of
# `adb shell input`: only the console can emit raw multi-touch (MT protocol B)
# events, which is what makes pinch/spread and two-finger gestures work at all.
# `adb shell input` is single-pointer only, and `sendevent` is SELinux-blocked.
$adbExe = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adbExe)) { $adbExe = 'adb' }

function Invoke-Adb {
  param([string[]]$Arguments)
  & $adbExe @Arguments 2>&1
}

function Get-GuestSize {
  $out = ''
  try { $out = (Invoke-Adb -Arguments @('shell', 'wm', 'size') | Out-String) } catch { $out = '' }
  $ms = [regex]::Matches($out, '(\d+)x(\d+)')
  if ($ms.Count -gt 0) { return $ms[$ms.Count - 1].Groups[1].Value + 'x' + $ms[$ms.Count - 1].Groups[2].Value }
  return '1080x2280'
}

$gsize = Get-GuestSize
$GSW = [int](($gsize -split 'x')[0])
$GSH = [int](($gsize -split 'x')[1])

# --- auto-start the WGC fast capturer (page falls back to PrintWindow if not) -
# --gsize lets the capturer crop its frames to the guest display, so the mirror
# maps browser pixels to guest pixels 1:1 (see the crop logic below).
$wgccapExe = Join-Path $PSScriptRoot '..\src\wgccap\bin\Release\net8.0-windows10.0.19041.0\wgccap.exe'
if (-not (Get-Process wgccap -ErrorAction SilentlyContinue)) {
  if (Test-Path $wgccapExe) {
    Start-Process -FilePath $wgccapExe -ArgumentList '--proc','qemu-system-x86_64','--port','8778','--gsize',$gsize -WindowStyle Hidden
    Write-Output 'WGC capturer (wgccap) started on http://127.0.0.1:8778/'
  } else {
    Write-Output 'wgccap.exe not built - PrintWindow fallback only (build src\wgccap for full-rate)'
  }
}

# the console listens on the emulator's adb port (emulator-5554 -> 5554)
$consolePort = 5554
try {
  foreach ($line in (Invoke-Adb -Arguments @('devices'))) {
    if ($line -match '^\s*emulator-(\d+)\s+device') { $consolePort = [int]$Matches[1]; break }
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
  $c.Connect('127.0.0.1', $consolePort)
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
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

    const uint PW_RENDERFULLCONTENT = 0x00000002;
    const uint SWP_NOZORDER  = 0x0004;
    const uint SWP_NOACTIVATE= 0x0010;
    const int  SW_RESTORE    = 9;
    const int  SW_SHOWNOACTIVATE = 8;
    const int  SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
    const int  SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    static RECT lastNormal; static bool haveLast;

    // User Alt-Tabs / taskbar-clicks an off-screen window -> put it back where it was.
    static void Track(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) return;
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return;
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        bool off = r.R <= vx || r.L >= vx + vw || r.B <= vy || r.T >= vy + vh;
        if (!off) { lastNormal = r; haveLast = true; return; }
        if (haveLast && GetForegroundWindow() == hwnd)
            SetWindowPos(hwnd, IntPtr.Zero, lastNormal.L, lastNormal.T,
                         lastNormal.R - lastNormal.L, lastNormal.B - lastNormal.T,
                         SWP_NOZORDER | SWP_NOACTIVATE);
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
        SetWindowPos(hwnd, IntPtr.Zero, vx + vw + 100, 200,
                     r.R - r.L, r.B - r.T, SWP_NOZORDER | SWP_NOACTIVATE);
        if (prev != IntPtr.Zero && prev != hwnd) SetForegroundWindow(prev);
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

# --- page served at / --------------------------------------------------------
$html = @'
<!doctype html><html><head><meta charset="utf-8"><title>AVD Mirror</title>
<style>
 html,body{margin:0;height:100%;background:#0d1117;color:#c9d1d9;font:12px system-ui,sans-serif}
 #wrap{display:flex;flex-direction:column;height:100%}
 /* Stage wraps the image so the power key can be positioned against the guest
    screen itself rather than the window, same as the soft keys below. */
 #stage{position:relative;flex:1;min-height:0;display:flex}
 #bar{padding:6px 10px;background:#161b22;display:flex;gap:10px;align-items:center;border-bottom:1px solid #30363d;flex-wrap:wrap}
 #m{flex:1;min-height:0;object-fit:contain;background:#000;cursor:crosshair;user-select:none;-webkit-user-select:none;touch-action:none}
 #st{color:#f85149}
 #inp{color:#d29922}
 #bar button{background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:5px;padding:2px 7px;font:12px system-ui,sans-serif;cursor:pointer;line-height:16px}
 #bar button:hover{background:#30363d}
  /* Soft nav keys sit under the screen, centred on 25/50/75% of the *displayed
     guest image* rather than the window: the image is object-fit:contain, so
     whenever there are side letterboxes the two widths differ and anchoring to
     the window would drift the keys off the guest's own nav positions. --imx/--imw
     carry the letterbox offset and displayed width, set by layoutNav(). */
  /* The bar is black, and the surface colour is painted only across the guest
     screen via ::before. The image is object-fit:contain on a #000 field, so
     the side letterbox here matches the letterbox directly above it and the two
     read as one continuous black surround instead of a stripe butting into the
     panel. --imx/--imw come from layoutNav(), so the strip tracks the screen. */
  #navbar{position:relative;flex:0 0 auto;height:38px;background:#000;--imx:0px;--imw:100%}
  #navbar::before{content:'';position:absolute;top:0;bottom:0;left:var(--imx);width:var(--imw);
   background:#161b22;border-top:1px solid #30363d;z-index:0}
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
  #navbar button[data-nav="back"]{left:calc(var(--imx) + var(--imw) * 0.25)}
  #navbar button[data-nav="home"]{left:calc(var(--imx) + var(--imw) * 0.5)}
  #navbar button[data-nav="recents"]{left:calc(var(--imx) + var(--imw) * 0.75)}
   /* Short viewports (the VS Code side panel is wide but only ~130 px tall) must
      give their space to the screen, not to chrome: the toolbar is a portrait
      phone squeezed by wrapping into three rows, which left the screen itself as a
      ~26x56 px sliver. Collapse everything to single-row, smaller controls. */
   @media (max-height:520px){
    #bar{padding:1px 5px;gap:5px;flex-wrap:nowrap;overflow:hidden;white-space:nowrap;font-size:10px}
    #bar b{display:none}
    #bar button{padding:0 4px;font-size:10px;line-height:12px}
    #navbar{height:26px}
    #navbar button{width:22px;height:22px;border-radius:5px}
    #navbar .ico{width:9px;height:9px}
    #pwr,.volkey{width:22px;height:44px;font-size:13px}
    #volup{top:calc(var(--imy) + var(--imh) * 0.4 - 22px)}
    #voldown{top:calc(var(--imy) + var(--imh) * 0.4 + 22px)}
   }
  /* Power and the two volume keys sit in the letterbox, flush against the
     screen's side edges, so they never cover guest content. --imx/--imw are the
     same letterbox offset and displayed width the soft keys use, and --imh the
     displayed height, so they track the guest screen at any window size. A narrow
     window can leave too little gutter, so each falls back to the edge it hugs. */
  #pwr,.volkey{position:absolute;transform:translateY(-50%);
   width:28px;height:84px;padding:0;z-index:2;
   display:flex;align-items:center;justify-content:center;
   background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;
   font:16px system-ui,sans-serif;cursor:pointer;line-height:1}
  #pwr{left:calc(var(--imx) + var(--imw));top:calc(var(--imy) + var(--imh) * 0.4);
   max-width:calc(100% - var(--imx) - var(--imw))}
  /* Left pair sits in the left letterbox: the key's right edge hugs the screen's
       left edge, mirroring how Power's left edge hugs the right edge. The two are
       offset by half their height (42 px) either side of the 40% line Power sits
       on, so they touch exactly at any window size and the pair stays centred
         where the right key is.
         The edge that must touch the screen is pinned with left + translateX(-100%),
         not by clamping the width. A `left: calc(var(--imx) - 28px)` position
         assumes a full 28 px key, so any width clamp also pulled the right edge
         clear of the screen and the keys detached as the panel narrowed; `right`
         cannot be used either, since it is measured from the stage's far edge.
         Anchoring the right edge this way holds at any key width or panel width. */
      #volup{left:var(--imx);transform:translate(-100%,-50%);top:calc(var(--imy) + var(--imh) * 0.4 - 42px)}
      #voldown{left:var(--imx);transform:translate(-100%,-50%);top:calc(var(--imy) + var(--imh) * 0.4 + 42px)}
  #pwr:hover,.volkey:hover{background:#30363d}
  #pwr:active,.volkey:active{background:#3d444d}
  </style></head>
 <body><div id="wrap">
  <div id="bar"><b>AVD Mirror</b><span id="st">connecting...</span><span id="src"></span><span id="fps"></span><span id="dim"></span>
   <button id="sdir">Natural &#8645;</button><span id="inp"></span></div>
  <div id="stage">
  <img id="m" alt="emulator" title="tap=left click &middot; touch &amp; hold=left press and hold &middot; swipe=left drag &middot; drag (press, hold, then move)=right press and drag &middot; scroll/fling=wheel (Natural: wheel down advances down the page) &middot; scroll sideways=shift+wheel &middot; scroll direction=toolbar &#8645; toggle &middot; pinch &amp; spread=Ctrl+drag or Ctrl+wheel &middot; Back=right click (no drag) &middot; Home=middle click &middot; edge drags=system nav gestures &middot; type=send keys"/>
   <button id="pwr" data-nav="power" title="Power" aria-label="Power">&#9211;</button>
   <button id="volup" class="volkey" data-nav="volup" title="Volume up" aria-label="Volume up">+</button>
   <button id="voldown" class="volkey" data-nav="voldown" title="Volume down" aria-label="Volume down">&#8722;</button>
  </div>
  <div id="navbar">
   <button data-nav="back" title="Back" aria-label="Back"><span class="ico ico-back"></span></button><button data-nav="home" title="Home" aria-label="Home"><span class="ico ico-home"></span></button><button data-nav="recents" title="Overview" aria-label="Overview"><span class="ico"></span></button>
  </div>
 <script>
const img=document.getElementById('m'),st=document.getElementById('st'),
      fps=document.getElementById('fps'),dim=document.getElementById('dim'),
      srcEl=document.getElementById('src'),navbar=document.getElementById('navbar'),
      stage=document.getElementById('stage');
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
async function grab(url,since){
  // The frame token goes in the query string, not a conditional request header: a
  // custom request header would turn every poll into a CORS preflighted
  // request and add a second round trip to each one.
  const sep=url.includes('?')?'&':'?';
  const u=since?url+sep+'since='+encodeURIComponent(since):url;
  const r=await fetch(u,{cache:'no-store',mode:'cors'});
  if(r.status===304) return null;                  // unchanged - nothing to decode
  if(!r.ok) throw new Error('HTTP '+r.status);
  const b=await r.blob();
  if(b.size<500) throw new Error('empty frame');
  const seq=r.headers.get('X-Frame-Seq');
  if(seq) frameSeq=seq.replace(/"/g,'');   // keep it a bare number for ?since=
  return b;
}
async function tick(){
  const tReq=performance.now(); let live=false, gotFrame=false;
  try{
    let b=null, got=false, srcName='';
    if(mode==='wgc'){
      try{ b=await grab('http://127.0.0.1:8778/frame.jpg?t='+Date.now(),frameSeq); got=true; srcName='WGC'; }
      catch(e){ if(++fails>=3){ mode='pw'; fails=0; } else throw e; }
    }
    if(!got){
      b=await grab('/frame.jpg?t='+Date.now());
      mode='pw'; srcName='PW';
      if(++probe>=25){ probe=0;
        try{ const b2=await grab('http://127.0.0.1:8778/frame.jpg?t='+Date.now(),frameSeq);
             mode='wgc'; fails=0; srcName='WGC'; if(b2!==null) b=b2; }catch(e){}
      }
    }
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
    st.textContent='live'; st.style.color='#3fb950';
    srcEl.textContent=srcName;
    const el=(performance.now()-t0)/1000;
    if(el>=1){ fps.textContent=(n/el).toFixed(0)+' fps'; n=0; t0=performance.now(); }
    live=true;
  }catch(e){ st.textContent='reconnecting... ('+e+')'; st.style.color='#f85149'; }
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
tick();

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
fetch('/gsize',{cache:'no-store'}).then(r=>r.text()).then(s=>{const m=s.match(/(\d+)x(\d+)/);
  if(m){GW=+m[1];GH=+m[2];} layoutNav();}).catch(()=>{note('gsize failed');});
layoutNav();

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
// displayed width (--imw) and the displayed height (--imh). The keys anchor to
// the bar, the power key to the stage, so each element gets the values relative
// to its own box.
function layoutNav(){
  const nb=navbar.getBoundingClientRect();
  const r=img.getBoundingClientRect();
  const iw=img.naturalWidth||GW, ih=img.naturalHeight||GH;
  const s=Math.min(r.width/iw,r.height/ih)||1;
  const dw=iw*s, dh=ih*s;
  const ox=r.left+(r.width-dw)/2, oy=r.top+(r.height-dh)/2;   // image box, viewport
  navbar.style.setProperty('--imx',(ox-nb.left)+'px');
  navbar.style.setProperty('--imw',dw+'px');
  const sg=stage.getBoundingClientRect();
  stage.style.setProperty('--imx',(ox-sg.left)+'px');
  stage.style.setProperty('--imw',dw+'px');
  stage.style.setProperty('--imy',(oy-sg.top)+'px');
  stage.style.setProperty('--imh',dh+'px');
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
const sdir=document.getElementById('sdir');
function paintSdir(){
  sdir.textContent=(naturalScroll?'Natural':'Classic')+' \u21C5';
  sdir.title=(naturalScroll
    ? 'Wheel down reveals content further down (natural)'
    : 'Wheel down reveals earlier content (classic)')+' - click to toggle';
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

function Send-Bytes([System.Net.Sockets.NetworkStream]$s, [string]$status, [string]$contentType, [byte[]]$body) {
  # frame-ancestors lets the page be embedded; the CORS headers let it also be
  # *inlined* into a VS Code webview, whose origin is not 127.0.0.1 and so cannot
  # read loopback responses without them. The listener is bound to loopback
  # only, so the exposure is other local processes (and any web page the user
  # happens to visit that reads 127.0.0.1:8777) - never the network.
  $head = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nContent-Security-Policy: frame-ancestors *`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Headers: *`r`nConnection: close`r`n`r`n"
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
Write-Output "guest $gsize  touch: emulator console 127.0.0.1:$consolePort"
[void](Send-Console 'ping')
if ($script:Console) { Write-Output 'emulator console connected - multi-touch gestures enabled' }
else { Write-Output 'WARNING: emulator console unreachable - touch input will fail (needs a running AVD)' }

while ($true) {
  if ($qemu.HasExited) { Write-Output 'EMULATOR_EXITED'; break }
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

    if ($path -like '/frame.jpg*') {
      $jpeg = [EmuMirrorWin]::Capture($hwnd, $rescue, $Quality, $GSW, $GSH)
      if ($jpeg) { Send-Bytes $stream '200 OK' 'image/jpeg' $jpeg }
      else       { Send-Bytes $stream '503 Service Unavailable' 'text/plain' ([byte[]][char[]]'capture failed') }
    }
    elseif ($path -eq '/' -or $path -like '/index*') {
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
      $p = Get-QueryParams $path
      $err = ''
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
        else { $err = 'unknown input cmd' }
      } catch { $err = $_.Exception.Message }
      if ($err) { Send-Bytes $stream '500 Server Error' 'text/plain' ([System.Text.Encoding]::UTF8.GetBytes($err)) }
      else      { Send-Bytes $stream '200 OK' 'text/plain' ([byte[]][char[]]'ok') }
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
