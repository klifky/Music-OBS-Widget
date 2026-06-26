# widget-tray.ps1 — Music OBS Widget tray manager

# Resolve the project folder whether running as a .ps1 script OR a ps2exe-compiled .exe.
# Under ps2exe there is no script file, so $MyInvocation is empty and we fall back to the
# running executable's own folder.
if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
$AssetDir   = Join-Path $ScriptDir "assets"     # tray icons / button images live here
$LogFile    = Join-Path $ScriptDir "widget-tray.log"
$EqScript   = Join-Path $ScriptDir "eq_capture.py"
$BpmScript   = Join-Path $ScriptDir "bpm_capture.py"
$SmtcScript = Join-Path $ScriptDir "smtc_reader.py"
$TrayPort   = 8766

function Log($msg) {
    "[$(Get-Date -Format 'HH:mm:ss')] $msg" | Out-File $LogFile -Append -Encoding UTF8
}

function Check-Command($cmd) {
    try { Get-Command $cmd -EA Stop | Out-Null; $true } catch { $false }
}

$NodeExe = @("node","$env:ProgramFiles\nodejs\node.exe") |
    Where-Object { try { if(Test-Path $_){$true}else{Get-Command $_ -EA Stop|Out-Null;$true}}catch{$false}} |
    Select-Object -First 1
if (!$NodeExe) { $NodeExe = "node" }

$PythonExe = @("python","python3") |
    Where-Object { Check-Command $_ } | Select-Object -First 1
if (!$PythonExe) { $PythonExe = "python" }

Log "Starting. Node=$NodeExe Python=$PythonExe"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Dependency check ──────────────────────────────────────────────────────────
# Runs once at startup. Verifies the things the widgets need to work and offers to
# auto-install the package dependencies. The virtual audio cable is NOT required
# (only the equalizer overlay uses it), so it is reported as optional info only.
function Test-Dependencies {
    $missing = @()   # hard requirements that block startup
    $fixable = @{}   # label -> install command we can run for the user

    # Node.js
    if (-not (Check-Command $NodeExe) -and -not (Test-Path $NodeExe)) {
        $missing += "Node.js  -  install from https://nodejs.org/"
    } else {
        # node modules (the 'ws' package)
        if (-not (Test-Path (Join-Path $ScriptDir "node_modules\ws"))) {
            $fixable["Node packages (npm install)"] = { Start-Process -FilePath "cmd.exe" -ArgumentList "/c","npm install" -WorkingDirectory $ScriptDir -Wait -WindowStyle Hidden }
        }
    }

    # Python
    if (-not (Check-Command $PythonExe)) {
        $missing += "Python 3  -  install from https://www.python.org/ (tick 'Add Python to PATH')"
    } else {
        # Probe a representative python module; if it is missing, assume requirements need installing
        & $PythonExe -c "import numpy, websocket, winrt.windows.media.control" 2>$null
        if ($LASTEXITCODE -ne 0 -and (Test-Path (Join-Path $ScriptDir "requirements.txt"))) {
            $fixable["Python packages (pip install -r requirements.txt)"] = { Start-Process -FilePath $PythonExe -ArgumentList "-m","pip","install","-r","requirements.txt" -WorkingDirectory $ScriptDir -Wait -WindowStyle Hidden }
        }
    }

    # Optional: virtual audio cable (equalizer only) - informational, never blocks
    $cablePresent = $false
    try {
        $cablePresent = [bool](Get-CimInstance Win32_SoundDevice -EA SilentlyContinue |
            Where-Object { $_.Name -match "CABLE|VB-Audio|Virtual" })
    } catch {}

    # Hard blockers: tell the user and stop.
    if ($missing.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "The following must be installed before Music OBS Widget can run:`n`n - " +
            ($missing -join "`n - ") +
            "`n`nInstall them, then start the app again.",
            "Music OBS Widget - missing requirements",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Log "Startup blocked, missing: $($missing -join '; ')"
        exit 1
    }

    # Fixable: offer to install packages automatically.
    if ($fixable.Count -gt 0) {
        $labels = $fixable.Keys -join "`n - "
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Some dependencies are not installed yet:`n`n - $labels`n`nInstall them now? (this may take a minute)",
            "Music OBS Widget - first-time setup",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($k in $fixable.Keys) {
                Log "Installing: $k"
                try { & $fixable[$k] } catch { Log "Install failed for ${k}: $_" }
            }
        } else {
            Log "User skipped auto-install of: $labels"
        }
    }

    if (-not $cablePresent) {
        Log "Note: no virtual audio cable detected (equalizer overlay will be inactive until one is set up)."
    }
}

Test-Dependencies

# ── WinAPI ────────────────────────────────────────────────────────────────────
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;

public class TrayWinApi {
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int x1,int y1,int x2,int y2,int cx,int cy);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT pt);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
}
"@

function Enable-Acrylic($form) { <# removed — using solid background #> }

function Set-Rounded($form, $r=16) {
    $rgn = [TrayWinApi]::CreateRoundRectRgn(0, 0, $form.Width, $form.Height, $r, $r)
    $form.Region = [System.Drawing.Region]::FromHrgn($rgn)
}

function Get-CursorPos {
    $pt = New-Object TrayWinApi+POINT
    [TrayWinApi]::GetCursorPos([ref]$pt) | Out-Null
    return $pt
}

# ── Load images ───────────────────────────────────────────────────────────────
function Load-Img($name) {
    $p = Join-Path $AssetDir $name
    if (Test-Path $p) { [System.Drawing.Image]::FromFile($p) } else { $null }
}

$imgServerOn  = Load-Img "server_on.png"
$imgServerOff = Load-Img "server_off.png"
$imgEqOn      = Load-Img "eq_on.png"
$imgEqOff     = Load-Img "eq_off.png"
$imgBuddyOn   = Load-Img "buddy_on.png"
$imgBuddyOff  = Load-Img "buddy_off.png"
$imgCableOn   = Load-Img "cable_on.png"
$imgCableOff  = Load-Img "cable_off.png"
$imgAppOn     = Load-Img "app_on.png"
$imgAppOff    = Load-Img "app_off.png"
$imgTick      = Load-Img "tick.png"

# ── Tray icon ─────────────────────────────────────────────────────────────────
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true

function Set-TrayIcon($on) {
    $ico  = if ($on) { "spotobs_on.ico" } else { "spotobs_off.ico" }
    $path = Join-Path $AssetDir $ico
    $newIcon = $null
    $created = $false
    try {
        if (Test-Path $path) {
            # Load at the system small-icon size so it stays crisp in the tray
            # (loading at default size can render blurry or cropped).
            $sz = [System.Windows.Forms.SystemInformation]::SmallIconSize
            $newIcon = New-Object System.Drawing.Icon($path, $sz)
            $created = $true
        }
    } catch { $newIcon = $null; $created = $false }
    if (-not $newIcon) { $newIcon = [System.Drawing.SystemIcons]::Application }

    $tray.Icon = $newIcon
    # Free the previously created icon handle (only ones we created ourselves)
    if ($script:trayIcon) { try { $script:trayIcon.Dispose() } catch {} }
    $script:trayIcon = if ($created) { $newIcon } else { $null }

    # Hover tooltip reflects server state
    $tray.Text = if ($on) { "Music OBS widget - active" } else { "Music OBS widget - disabled" }
}
Set-TrayIcon $false

# ── State ─────────────────────────────────────────────────────────────────────
$serverProcess = $null
$smtcProcess   = $null
$eqProcess     = $null
$bpmProcess    = $null
$menuForm      = $null
$subMenuForm   = $null
$hoverMap      = @{}
$timerMap      = @{}

function Get-IsRunning($p) { $p -and -not $p.HasExited }

# Kill a process AND its child tree. Start-Process for python/node can return a
# launcher/shim PID whose real worker is a child — Stop-Process -Id would orphan it.
function Kill-Tree($p) {
    if (!$p -or !$p.Id) { return }
    try { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null } catch {}
}

# Kill any process whose command line matches $needle (e.g. an eq_capture.py left
# over from a crash or a stale launcher PID). Makes Start/Stop idempotent and
# prevents duplicate captures fighting over the loopback device.
function Kill-Stray($needle) {
    try {
        Get-CimInstance Win32_Process -EA Stop |
            Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$needle*") } |
            ForEach-Object {
                try { & taskkill.exe /PID $_.ProcessId /T /F 2>$null | Out-Null } catch {}
            }
    } catch {}
}

# ── Colors / fonts ────────────────────────────────────────────────────────────
$clrBg      = [System.Drawing.Color]::FromArgb(22, 22, 22)
$clrHover   = [System.Drawing.Color]::FromArgb(45, 255, 255, 255)
$clrClear   = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
$clrText    = [System.Drawing.Color]::White
$clrSub     = [System.Drawing.Color]::FromArgb(140, 140, 140)
$clrSep     = [System.Drawing.Color]::FromArgb(55, 55, 55)
$fontMain   = New-Object System.Drawing.Font("Segoe UI", 10)
$fontBold   = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$fontSmall  = New-Object System.Drawing.Font("Segoe UI", 9)

# ── Theme display names ───────────────────────────────────────────────────────
function Get-ThemeLabel($target) {
    switch ($target) {
        "eq"    { "equalizer" }
        "buddy" { "Jam Buddy" }
        default { "player" }
    }
}

# ── Close helpers ─────────────────────────────────────────────────────────────
function Close-Sub {
    if ($script:subMenuForm -and -not $script:subMenuForm.IsDisposed) {
        $script:subMenuForm.Close()
        $script:subMenuForm = $null
    }
}

function Close-Menu {
    Close-Sub
    if ($script:menuForm -and -not $script:menuForm.IsDisposed) {
        $script:menuForm.Close()
        $script:menuForm = $null
    }
}

# ── Row builder ───────────────────────────────────────────────────────────────
# New-Row: main toggle row
function New-Row($parent, $img, $text, $y, $onClick) {
    $row = New-Object System.Windows.Forms.Panel
    $row.Size      = New-Object System.Drawing.Size(300, 44)
    $row.Location  = New-Object System.Drawing.Point(0, $y)
    $row.BackColor = [System.Drawing.Color]::FromArgb(0,0,0,0)
    $row.Cursor    = [System.Windows.Forms.Cursors]::Hand

    if ($img) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image     = $img
        $pic.Size      = New-Object System.Drawing.Size(26, 26)
        $pic.Location  = New-Object System.Drawing.Point(16, 9)
        $pic.SizeMode  = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $pic.BackColor = [System.Drawing.Color]::Transparent
        $row.Controls.Add($pic)
    }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $text
    $lbl.ForeColor = $clrText
    $lbl.Font      = $fontMain
    $lbl.Location  = New-Object System.Drawing.Point(52, 13)
    $lbl.Size      = New-Object System.Drawing.Size(230, 20)
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $row.Controls.Add($lbl)

    $row.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(40,255,255,255) })
    $row.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::FromArgb(0,0,0,0) })
    foreach ($c in $row.Controls) {
        $c.Add_MouseEnter({ $this.Parent.BackColor = [System.Drawing.Color]::FromArgb(40,255,255,255) })
        $c.Add_MouseLeave({ $this.Parent.BackColor = [System.Drawing.Color]::FromArgb(0,0,0,0) })
    }
    if ($onClick) {
        $row.Add_Click($onClick)
        foreach ($c in $row.Controls) { $c.Add_Click($onClick) }
    }

    $parent.Controls.Add($row)
    return $lbl
}


# New-BuddyParamRow: checkbox + label + numeric input for buddy settings
function New-BuddyParamRow($parent, $y, $label, $cfgKey, $cfgValKey, $defaultVal) {
    $cfg = Read-WidgetConfig
    $checked = if ($null -ne $cfg[$cfgKey]) { [bool]$cfg[$cfgKey] } else { $true }
    $val     = if ($null -ne $cfg[$cfgValKey]) { [int]$cfg[$cfgValKey] } else { $defaultVal }

    # Checkbox
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Checked   = $checked
    $chk.Location  = New-Object System.Drawing.Point(54, ($y + 1))
    $chk.Size      = New-Object System.Drawing.Size(14, 14)
    $chk.BackColor = [System.Drawing.Color]::Transparent
    $chk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $chk.FlatAppearance.BorderColor = $clrSub
    $chk.FlatAppearance.CheckedBackColor = [System.Drawing.Color]::FromArgb(80, 160, 80)
    $parent.Controls.Add($chk)

    # Label
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $label
    $lbl.ForeColor = $clrSub
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lbl.Location  = New-Object System.Drawing.Point(72, $y)
    $lbl.Size      = New-Object System.Drawing.Size(150, 16)
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($lbl)

    # Numeric input
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum  = 1
    $num.Maximum  = 999
    $num.Value    = [Math]::Max(1, [Math]::Min(999, $val))
    $num.Width    = 48
    $num.Height   = 18
    $num.Location = New-Object System.Drawing.Point(224, ($y - 1))
    $num.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
    $num.BackColor = $clrBg
    $num.ForeColor = $clrText
    $num.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $num.Enabled  = $checked
    $parent.Controls.Add($num)

    # Store keys in Tag so scriptblocks can read them without closure issues
    $chk.Tag = @{ ck = $cfgKey; vk = $cfgValKey; num = $num }
    $num.Tag = @{ ck = $cfgKey; vk = $cfgValKey; chk = $chk }

    $chkAction = {
        $t = $this.Tag
        $c = Read-WidgetConfig
        $c[$t.ck] = $this.Checked
        $c[$t.vk] = [int]$t.num.Value
        Write-WidgetConfig $c
        $t.num.Enabled = $this.Checked
    }.GetNewClosure()

    $numAction = {
        $t = $this.Tag
        $c = Read-WidgetConfig
        $c[$t.ck] = $t.chk.Checked
        $c[$t.vk] = [int]$this.Value
        Write-WidgetConfig $c
    }.GetNewClosure()

    $chk.Add_CheckedChanged($chkAction)
    $num.Add_ValueChanged($numAction)
}

# New-BuddyCheckRow: checkbox + label only, writes a single bool config key.
function New-BuddyCheckRow($parent, $y, $label, $cfgKey, $defaultVal) {
    $cfg = Read-WidgetConfig
    $checked = if ($null -ne $cfg[$cfgKey]) { [bool]$cfg[$cfgKey] } else { [bool]$defaultVal }

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Checked   = $checked
    $chk.Location  = New-Object System.Drawing.Point(54, ($y + 1))
    $chk.Size      = New-Object System.Drawing.Size(14, 14)
    $chk.BackColor = [System.Drawing.Color]::Transparent
    $chk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $chk.FlatAppearance.BorderColor = $clrSub
    $chk.FlatAppearance.CheckedBackColor = [System.Drawing.Color]::FromArgb(80, 160, 80)
    $parent.Controls.Add($chk)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $label
    $lbl.ForeColor = $clrSub
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lbl.Location  = New-Object System.Drawing.Point(72, $y)
    $lbl.Size      = New-Object System.Drawing.Size(220, 16)
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($lbl)

    $chk.Tag = @{ ck = $cfgKey }
    $chk.Add_CheckedChanged({
        $c = Read-WidgetConfig
        $c[$this.Tag.ck] = $this.Checked
        Write-WidgetConfig $c
    }.GetNewClosure())
}

# New-BuddyNumRow: label + numeric only (always enabled), writes a single int key.
function New-BuddyNumRow($parent, $y, $label, $cfgValKey, $defaultVal, $min, $max) {
    $cfg = Read-WidgetConfig
    $val = if ($null -ne $cfg[$cfgValKey]) { [int]$cfg[$cfgValKey] } else { [int]$defaultVal }

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = $label
    $lbl.ForeColor = $clrSub
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lbl.Location  = New-Object System.Drawing.Point(72, $y)
    $lbl.Size      = New-Object System.Drawing.Size(150, 16)
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($lbl)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum  = $min
    $num.Maximum  = $max
    $num.Value    = [Math]::Max($min, [Math]::Min($max, $val))
    $num.Width    = 48
    $num.Height   = 18
    $num.Location = New-Object System.Drawing.Point(224, ($y - 1))
    $num.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
    $num.BackColor = $clrBg
    $num.ForeColor = $clrText
    $num.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $parent.Controls.Add($num)

    $num.Tag = @{ vk = $cfgValKey }
    $num.Add_ValueChanged({
        $c = Read-WidgetConfig
        $c[$this.Tag.vk] = [int]$this.Value
        Write-WidgetConfig $c
    }.GetNewClosure())
}

# New-ThemeRow: small "Choose theme" link below main row
function New-ThemeRow($parent, $y, $target) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = "Choose $(Get-ThemeLabel $target) theme"
    $lbl.ForeColor = $clrSub
    $lbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lbl.Location  = New-Object System.Drawing.Point(54, $y)
    $lbl.Size      = New-Object System.Drawing.Size(200, 16)
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $lbl.Tag       = $target
    $lbl.Add_MouseEnter({ $this.ForeColor = $clrText })
    $lbl.Add_MouseLeave({ $this.ForeColor = $clrSub })
    $lbl.Add_Click({ Close-Menu; Show-ThemePicker $this.Tag })
    $parent.Controls.Add($lbl)
}

# ── Submenu ────────────────────────────────────────────────────────────────────
function Show-Sub($anchorControl, $items) {
    Close-Sub

    $rowH  = 44
    $h     = $items.Count * $rowH + 16
    $w     = 200

    $sub = New-Object System.Windows.Forms.Form
    $script:subMenuForm = $sub
    $sub.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $sub.ShowInTaskbar   = $false
    $sub.TopMost         = $true
    $sub.Width           = $w
    $sub.Height          = $h
    $sub.BackColor       = $clrBg
    $sub.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual

    # Position to the right of anchor
    $screenPt = $anchorControl.Parent.PointToScreen($anchorControl.Location)
    $sub.Left = $screenPt.X + $anchorControl.Width + 4
    $sub.Top  = $screenPt.Y

    # Keep inside screen
    $screen = [System.Windows.Forms.Screen]::FromPoint($screenPt).WorkingArea
    if ($sub.Right -gt $screen.Right) { $sub.Left = $screenPt.X - $w - 4 }
    if ($sub.Bottom -gt $screen.Bottom) { $sub.Top = $screen.Bottom - $h }

    Set-Rounded $sub 12
    Enable-Acrylic $sub

    $y = 8
    foreach ($item in $items) {
        $btn = New-Object System.Windows.Forms.Label
        $btn.Text      = $item.Text
        $btn.ForeColor = $clrText
        $btn.Font      = $fontMain
        $btn.Location  = New-Object System.Drawing.Point(16, $y)
        $btn.Size      = New-Object System.Drawing.Size(168, 36)
        $btn.BackColor = [System.Drawing.Color]::Transparent
        $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $btn.Tag       = $item.Action
        $btn.Add_MouseEnter({ $this.BackColor = $clrHover })
        $btn.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::Transparent })
        $btn.Add_Click({
            & $this.Tag
            Close-Menu
        })
        $sub.Controls.Add($btn)
        $y += $rowH
    }

    $sub.Add_Deactivate({ if (-not $script:subMenuForm.IsDisposed) { Close-Sub } })
    try { $sub.Show() } catch {}
}

# ── Main menu ─────────────────────────────────────────────────────────────────
function Show-Menu {
    Close-Menu

    $form = New-Object System.Windows.Forms.Form
    $script:menuForm = $form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.Width           = 320
    $form.Height          = 572
    $form.BackColor       = $clrBg
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual

    # Position above tray icon (near cursor)
    $cursor = Get-CursorPos
    $screen = [System.Windows.Forms.Screen]::FromPoint(
        (New-Object System.Drawing.Point($cursor.X, $cursor.Y))).WorkingArea
    $form.Left = [Math]::Min($cursor.X - $form.Width / 2, $screen.Right - $form.Width - 8)
    $form.Left = [Math]::Max($form.Left, $screen.Left + 8)
    $form.Top  = $screen.Bottom - $form.Height - 8

    # ── Header ────────────────────────────────────────────────────────────────
    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Size      = New-Object System.Drawing.Size(320, 60)
    $hdr.Location  = New-Object System.Drawing.Point(0, 0)
    $hdr.BackColor = [System.Drawing.Color]::Transparent
    $hdr.Cursor    = [System.Windows.Forms.Cursors]::Default

    $icoPath = Join-Path $AssetDir "spotobs_on.ico"
    if (Test-Path $icoPath) {
        # Load at an explicit size and guard it: some .ico files carry a PNG-compressed
        # frame that makes Icon.ToBitmap() throw "range extends past the end of the array".
        # The logo is decorative, so on any failure we just skip it.
        $logoBmp = $null
        try {
            $logoIco = New-Object System.Drawing.Icon($icoPath, 32, 32)
            $logoBmp = $logoIco.ToBitmap()
            $logoIco.Dispose()
        } catch {
            try { $logoBmp = [System.Drawing.Image]::FromFile($icoPath) } catch { $logoBmp = $null }
        }
        if ($logoBmp) {
            $logoPic = New-Object System.Windows.Forms.PictureBox
            $logoPic.Image    = $logoBmp
            $logoPic.Size     = New-Object System.Drawing.Size(30, 30)
            $logoPic.Location = New-Object System.Drawing.Point(16, 15)
            $logoPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
            $logoPic.BackColor = [System.Drawing.Color]::Transparent
            $hdr.Controls.Add($logoPic)
        }
    }

    $titleLbl = New-Object System.Windows.Forms.Label
    $titleLbl.Text      = "MOBSW"
    $titleLbl.ForeColor = $clrText
    $titleLbl.Font      = $fontBold
    $titleLbl.Location  = New-Object System.Drawing.Point(0, 17)
    $titleLbl.Size      = New-Object System.Drawing.Size(320, 26)
    $titleLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $titleLbl.BackColor = [System.Drawing.Color]::Transparent
    $hdr.Controls.Add($titleLbl)

    # No drag — tray menu stays fixed
    $form.Controls.Add($hdr)

    # Sep
    $s1 = New-Object System.Windows.Forms.Panel
    $s1.Size=$([System.Drawing.Size]::new(288,1)); $s1.Location=$([System.Drawing.Point]::new(16,60))
    $s1.BackColor=$clrSep; $form.Controls.Add($s1)

    # ── Rows ──────────────────────────────────────────────────────────────────
    $srvOn = Get-IsRunning $script:serverProcess
    $eqOn  = Get-IsRunning $script:eqProcess

    $srvImg   = if ($srvOn) { $imgServerOn } else { $imgServerOff }
    $srvTxt   = if ($srvOn) { "Widget server - On" } else { "Widget server - Off" }
    $eqImg    = if ($eqOn)  { $imgEqOn     } else { $imgEqOff     }
    $eqTxt    = if ($eqOn)  { "Widget Equalizer - On" } else { "Widget Equalizer - Off" }
    $cableImg = if ($eqOn)  { $imgCableOn  } else { $imgCableOff  }
    $appImg   = if ($srvOn) { $imgAppOn    } else { $imgAppOff    }

    # Widget server row + theme link
    New-Row $form $srvImg $srvTxt 68 {
        if(Get-IsRunning $script:serverProcess){Stop-Widget}else{Start-Widget}; Close-Menu
    } | Out-Null
    New-ThemeRow $form 114 "widget"

    # Separator
    $s2a = New-Object System.Windows.Forms.Panel
    $s2a.Size=New-Object System.Drawing.Size(288,1); $s2a.Location=New-Object System.Drawing.Point(16,133)
    $s2a.BackColor=$clrSep; $form.Controls.Add($s2a)

    # Equalizer row + theme link
    New-Row $form $eqImg $eqTxt 141 {
        if(Get-IsRunning $script:eqProcess){Stop-Eq}else{Start-Eq}; Close-Menu
    } | Out-Null
    New-ThemeRow $form 187 "eq"

    # Separator
    $s2b = New-Object System.Windows.Forms.Panel
    $s2b.Size=New-Object System.Drawing.Size(288,1); $s2b.Location=New-Object System.Drawing.Point(16,206)
    $s2b.BackColor=$clrSep; $form.Controls.Add($s2b)

    # Jam Buddy row + theme link + param rows
    $buddyOn  = Get-IsRunning $script:bpmProcess
    $buddyImg = if ($buddyOn) { $imgBuddyOn } else { $imgBuddyOff }
    $buddyTxt = if ($buddyOn) { "Jam Buddy - On" } else { "Jam Buddy - Off" }
    New-Row $form $buddyImg $buddyTxt 214 {
        if(Get-IsRunning $script:bpmProcess){Stop-Buddy}else{Start-Buddy}; Close-Menu
    } | Out-Null
    New-ThemeRow $form 260 "buddy"
    New-BuddyParamRow $form 278 "Lock BPM overrange" "buddy_lock_overrange" "buddy_lock_bpm"    140
    New-BuddyParamRow $form 296 "Dynamic BPM update (s)" "buddy_update_enabled"  "buddy_update_rate" 30
    New-BuddyCheckRow $form 314 "High-accuracy detection (spectral flux)" "buddy_method_flux" $true
    New-BuddyNumRow   $form 332 "Analysis window (s)" "buddy_window_sec" 6 3 20

    # Apply & Reload Buddy — forces bpm_capture.py to restart with the new params
    $applyLbl = New-Object System.Windows.Forms.Label
    $applyLbl.Text      = "Apply and reload Jam Buddy"
    $applyLbl.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100)
    $applyLbl.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $applyLbl.Location  = New-Object System.Drawing.Point(54, 352)
    $applyLbl.Size      = New-Object System.Drawing.Size(220, 16)
    $applyLbl.BackColor = [System.Drawing.Color]::Transparent
    $applyLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $applyLbl.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(160,255,160) })
    $applyLbl.Add_MouseLeave({ $this.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100) })
    $applyLbl.Add_Click({
        Close-Menu
        if (Get-IsRunning $script:bpmProcess) {
            Stop-Buddy | Out-Null
            Start-Sleep -Milliseconds 400   # let the WS client drop + device free
            Start-Buddy | Out-Null
            Log "Jam Buddy reloaded with new params"
        } else {
            Log "Jam Buddy not running - params saved, applied on next start"
        }
    })
    $form.Controls.Add($applyLbl)

    # Separator
    $s2 = New-Object System.Windows.Forms.Panel
    $s2.Size=New-Object System.Drawing.Size(288,1); $s2.Location=New-Object System.Drawing.Point(16,376)
    $s2.BackColor=$clrSep; $form.Controls.Add($s2)

    # Capture device row
    New-Row $form $cableImg "Select capture device" 384 { Close-Menu; Show-DevicePicker } | Out-Null

    # Music source row (which app the player reads now-playing info from)
    New-Row $form $appImg "Select music source" 428 { Close-Menu; Show-SourcePicker } | Out-Null

    # Separator above footer
    $s3 = New-Object System.Windows.Forms.Panel
    $s3.Size=$([System.Drawing.Size]::new(288,1)); $s3.Location=$([System.Drawing.Point]::new(16,472))
    $s3.BackColor=$clrSep; $form.Controls.Add($s3)

    # Autostart with system. Point the Startup shortcut at THIS running executable,
    # whatever it is named (MOBSW.exe, widget-tray.exe, ...), so renaming never breaks it.
    # When run as a .ps1 in development the host is powershell.exe, so we fall back to a
    # sensible default name in the project folder.
    $startupDir  = [System.Environment]::GetFolderPath("Startup")
    $startupLnk  = Join-Path $startupDir "MusicOBSWidget.lnk"
    $legacyLnk   = Join-Path $startupDir "MOBSW.lnk"   # old name, cleaned up
    $selfExe = $null
    try {
        $mm = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($mm -and $mm -notmatch 'powershell|pwsh') { $selfExe = $mm }
    } catch {}
    $exeLauncher = if ($selfExe) { $selfExe } else { Join-Path $ScriptDir "MOBSW.exe" }
    $autostartOn = (Test-Path $startupLnk) -or (Test-Path $legacyLnk)

    $autoLbl = New-Object System.Windows.Forms.Label
    $autoLbl.Text      = if ($autostartOn) { "Autostart with system: On" } else { "Autostart with system: Off" }
    $autoLbl.ForeColor = if ($autostartOn) { [System.Drawing.Color]::FromArgb(100,200,100) } else { $clrSub }
    $autoLbl.Font      = $fontSmall
    $autoLbl.Location  = New-Object System.Drawing.Point(0, 480)
    $autoLbl.Size      = New-Object System.Drawing.Size(320, 28)
    $autoLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $autoLbl.BackColor = [System.Drawing.Color]::Transparent
    $autoLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $autoLbl.Tag       = @{ lnk = $startupLnk; legacy = $legacyLnk; exe = $exeLauncher; dir = $ScriptDir }
    $autoLbl.Add_MouseEnter({ $this.ForeColor = $clrText })
    $autoLbl.Add_MouseLeave({
        $on = (Test-Path $this.Tag.lnk) -or (Test-Path $this.Tag.legacy)
        $this.ForeColor = if ($on) { [System.Drawing.Color]::FromArgb(100,200,100) } else { $clrSub }
    })
    $autoLbl.Add_Click({
        $t  = $this.Tag
        if ((Test-Path $t.lnk) -or (Test-Path $t.legacy)) {
            Remove-Item $t.lnk    -Force -EA SilentlyContinue
            Remove-Item $t.legacy -Force -EA SilentlyContinue   # remove old-named shortcut too
            $this.Text = "Autostart with system: Off"; $this.ForeColor = $clrSub
            Log "Autostart disabled"
        } elseif (Test-Path $t.exe) {
            $wsh = New-Object -ComObject WScript.Shell
            $lnk = $wsh.CreateShortcut($t.lnk)
            $lnk.TargetPath = $t.exe; $lnk.WorkingDirectory = $t.dir; $lnk.Save()
            $this.Text = "Autostart with system: On"
            $this.ForeColor = [System.Drawing.Color]::FromArgb(100,200,100)
            Log "Autostart enabled"
        } else {
            [System.Windows.Forms.MessageBox]::Show("Executable not found at $($t.exe). Build it with source\build-exe.ps1 first, then run the .exe.",
                "Music OBS Widget","OK","Warning") | Out-Null
        }
    })
    $form.Controls.Add($autoLbl)

    # Exit
    $exitLbl = New-Object System.Windows.Forms.Label
    $exitLbl.Text      = "Exit"
    $exitLbl.ForeColor = $clrSub
    $exitLbl.Font      = $fontSmall
    $exitLbl.Location  = New-Object System.Drawing.Point(0, 508)
    $exitLbl.Size      = New-Object System.Drawing.Size(320, 28)
    $exitLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $exitLbl.BackColor = [System.Drawing.Color]::Transparent
    $exitLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $exitLbl.Add_MouseEnter({ $this.ForeColor = [System.Drawing.Color]::FromArgb(255,100,100) })
    $exitLbl.Add_MouseLeave({ $this.ForeColor = $clrSub })
    $exitLbl.Add_Click({
        Close-Menu
        Stop-Widget | Out-Null
        Stop-Eq | Out-Null
        Stop-Buddy | Out-Null
        $tray.Visible = $false
        $listener.Stop()
        [System.Windows.Forms.Application]::Exit()
    })
    $form.Controls.Add($exitLbl)

    # About
    $aboutLbl = New-Object System.Windows.Forms.Label
    $aboutLbl.Text      = "About"
    $aboutLbl.ForeColor = $clrSub
    $aboutLbl.Font      = $fontSmall
    $aboutLbl.Location  = New-Object System.Drawing.Point(0, 536)
    $aboutLbl.Size      = New-Object System.Drawing.Size(320, 28)
    $aboutLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $aboutLbl.BackColor = [System.Drawing.Color]::Transparent
    $aboutLbl.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $aboutLbl.Add_MouseEnter({ $this.ForeColor = $clrText })
    $aboutLbl.Add_MouseLeave({ $this.ForeColor = $clrSub })
    $aboutLbl.Add_Click({
        Close-Menu
        [System.Windows.Forms.MessageBox]::Show(
            "Music OBS Widget`nv1.1.0`n`ngithub.com/klifky/Music-OBS-widget",
            "About","OK","Information") | Out-Null
    })
    $form.Controls.Add($aboutLbl)

    $form.Add_Deactivate({ if(-not($script:subMenuForm -and $script:subMenuForm.Focused)){Close-Menu} })
    Set-Rounded $form 16
    $form.Show()
    $form.Activate()
}

# ── Widget / EQ functions ─────────────────────────────────────────────────────
function Start-Widget {
    if (Get-IsRunning $script:serverProcess) { return "already" }
    # Clear any orphaned server/SMTC from a previous crash before launching
    Kill-Stray "server.js"
    Kill-Stray "smtc_reader.py"
    $script:serverProcess = Start-Process -FilePath $NodeExe -ArgumentList "server.js" `
        -WorkingDirectory $ScriptDir -PassThru -WindowStyle Hidden
    Log "Widget started PID=$($script:serverProcess.Id)"
    Start-Sleep -Milliseconds 800
    if (Test-Path $SmtcScript) {
        $script:smtcProcess = Start-Process -FilePath $PythonExe `
            -ArgumentList "`"$SmtcScript`"" -WorkingDirectory $ScriptDir -PassThru -WindowStyle Hidden
        Log "SMTC started PID=$($script:smtcProcess.Id)"
    }
    Set-TrayIcon $true
    return "started"
}

function Stop-Widget {
    $wasRunning = Get-IsRunning $script:serverProcess
    Kill-Tree $script:smtcProcess;   Kill-Stray "smtc_reader.py"; $script:smtcProcess   = $null
    Kill-Tree $script:serverProcess; Kill-Stray "server.js";      $script:serverProcess = $null
    Set-TrayIcon $false
    Stop-Eq | Out-Null
    Stop-Buddy | Out-Null
    Log "Widget stopped"
    if ($wasRunning) { return "stopped" } else { return "already" }
}

function Get-Status { if (Get-IsRunning $script:serverProcess) {"running"} else {"stopped"} }

function Start-Eq {
    if (Get-IsRunning $script:eqProcess) { return "already" }
    if (!(Test-Path $EqScript)) { return "error" }
    Kill-Stray "eq_capture.py"
    $script:eqProcess = Start-Process -FilePath $PythonExe `
        -ArgumentList "`"$EqScript`"" -WorkingDirectory $ScriptDir -PassThru -WindowStyle Hidden
    Log "EQ started PID=$($script:eqProcess.Id)"
    return "started"
}

function Stop-Eq {
    $wasRunning = Get-IsRunning $script:eqProcess
    Kill-Tree $script:eqProcess; Kill-Stray "eq_capture.py"; $script:eqProcess = $null
    Log "EQ stopped"
    if ($wasRunning) { return "stopped" } else { return "already" }
}

function Get-EqStatus {
    if (Get-IsRunning $script:eqProcess) { return "running" }
    # Also detect if started externally
    $found = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -like "*eq_capture*" }
    if ($found) { return "running" }
    return "stopped"
}

function Start-Buddy {
    if (Get-IsRunning $script:bpmProcess) { return "already" }
    if (!(Test-Path $BpmScript)) { return "error" }
    Kill-Stray "bpm_capture.py"
    $script:bpmProcess = Start-Process -FilePath $PythonExe `
        -ArgumentList "`"$BpmScript`"" -WorkingDirectory $ScriptDir -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    if (!$script:bpmProcess -or $script:bpmProcess.HasExited) {
        Log "Buddy exited immediately - check Python and dependencies"
        $script:bpmProcess = $null
        return "error"
    }
    Log "Buddy started PID=$($script:bpmProcess.Id)"
    return "started"
}

function Stop-Buddy {
    $wasRunning = Get-IsRunning $script:bpmProcess
    Kill-Tree $script:bpmProcess; Kill-Stray "bpm_capture.py"; $script:bpmProcess = $null
    Log "Buddy stopped"
    if ($wasRunning) { return "stopped" } else { return "already" }
}

function Get-BuddyStatus {
    if (Get-IsRunning $script:bpmProcess) { return "running" }
    $found = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='python3.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -like "*bpm_capture*" }
    if ($found) { return "running" }
    return "stopped"
}
function Read-WidgetConfig {
    $configPath = Join-Path $ScriptDir "widget_config.json"
    $defaults = @{
        widget_theme         = "infinite"
        eq_theme             = "glowed"
        buddy_theme          = "default"
        buddy_lock_overrange = $true
        buddy_lock_bpm       = 140
        buddy_update_enabled = $true
        buddy_update_rate    = 30
        buddy_method_flux    = $true
        buddy_window_sec     = 6
        source_app_id        = ""
    }
    if (Test-Path $configPath) {
        try {
            $json = Get-Content $configPath -Raw | ConvertFrom-Json
            # Merge into hashtable so Add/set operations are reliable
            $ht = @{}
            $json.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            foreach ($k in $defaults.Keys) { if (-not $ht.ContainsKey($k)) { $ht[$k] = $defaults[$k] } }
            return $ht
        } catch {}
    }
    return $defaults
}

function Write-WidgetConfig($cfg) {
    $configPath = Join-Path $ScriptDir "widget_config.json"
    # Write UTF-8 WITHOUT BOM. Set-Content -Encoding UTF8 adds a BOM in Windows
    # PowerShell 5.1, which breaks Python's json (utf-8) and Node's JSON.parse.
    $json = $cfg | ConvertTo-Json
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Themes($type) {
    $dir = switch ($type) { "eq" { "eq_themes" } "buddy" { "jam_buddy_themes" } default { "player_themes" } }
    $base = Join-Path $ScriptDir $dir
    if (-not (Test-Path $base)) { return @() }
    return Get-ChildItem $base -Directory | Select-Object -ExpandProperty Name
}

function Show-ThemePicker($target) {
    $isEq   = $target -eq "eq"
    $label  = Get-ThemeLabel $target
    $themes = Get-Themes $target

    if (!$themes -or $themes.Count -eq 0) {
        $dirName = switch ($target) { "eq" { "eq_themes" } "buddy" { "jam_buddy_themes" } default { "player_themes" } }
        [System.Windows.Forms.MessageBox]::Show(
            "No themes found.`nAdd folders to $dirName\.",
            "Music OBS Widget","OK","Information") | Out-Null
        return
    }

    $cfg     = Read-WidgetConfig
    $current = if ($isEq) { $cfg["eq_theme"] } elseif ($target -eq "buddy") { $cfg["buddy_theme"] } else { $cfg["widget_theme"] }

    $rowH = 44
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.BackColor       = $clrBg
    $form.Width           = 380
    $form.Height          = 108 + $themes.Count * $rowH + 38
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    Set-Rounded $form 16
    Enable-Acrylic $form

    $t1 = New-Object System.Windows.Forms.Label
    $t1.Text      = "Choose $label theme"
    $t1.ForeColor = $clrText
    $t1.Font      = $fontBold
    $t1.Location  = New-Object System.Drawing.Point(20, 16)
    $t1.Size      = New-Object System.Drawing.Size(340, 26)
    $t1.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($t1)

    $t2 = New-Object System.Windows.Forms.Label
    $t2.Text      = "Select a theme for the $label widget:"
    $t2.ForeColor = $clrSub
    $t2.Font      = $fontSmall
    $t2.Location  = New-Object System.Drawing.Point(20, 44)
    $t2.Size      = New-Object System.Drawing.Size(340, 20)
    $t2.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($t2)

    $sp = New-Object System.Windows.Forms.Panel
    $sp.Size      = New-Object System.Drawing.Size(340, 1)
    $sp.Location  = New-Object System.Drawing.Point(20, 70)
    $sp.BackColor = $clrSep
    $form.Controls.Add($sp)

    $y = 78
    $script:selectedTheme = $null

    foreach ($theme in $themes) {
        $isSelected = $theme -eq $current

        $r = New-Object System.Windows.Forms.Panel
        $r.Size      = New-Object System.Drawing.Size(380, $rowH)
        $r.Location  = New-Object System.Drawing.Point(0, $y)
        $r.BackColor = if ($isSelected) { [System.Drawing.Color]::FromArgb(40, 80, 200, 80) } else { [System.Drawing.Color]::FromArgb(0,0,0,0) }
        $r.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $r.Tag       = $theme

        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $theme
        $l.Font      = $fontMain
        $l.ForeColor = if ($isSelected) { [System.Drawing.Color]::FromArgb(120, 220, 120) } else { $clrText }
        $l.Location  = New-Object System.Drawing.Point(20, 12)
        $l.Size      = New-Object System.Drawing.Size(260, 22)
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.Tag       = $theme
        $r.Controls.Add($l)

        if ($isSelected) {
            $tick = New-Object System.Windows.Forms.Label
            $tick.Text      = "selected"
            $tick.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 120)
            $tick.Font      = $fontMain
            $tick.Location  = New-Object System.Drawing.Point(300, 12)
            $tick.Size      = New-Object System.Drawing.Size(60, 22)
            $tick.BackColor = [System.Drawing.Color]::Transparent
            $tick.Tag       = $theme
            $r.Controls.Add($tick)
        }

        $r.Add_MouseEnter({ $this.BackColor = [System.Drawing.Color]::FromArgb(45,255,255,255) })
        $r.Add_MouseLeave({
            $n = $this.Tag
            $cfg_now = Read-WidgetConfig
            $cur_now = if ($script:themeTarget -eq "eq") { $cfg_now["eq_theme"] } elseif ($script:themeTarget -eq "buddy") { $cfg_now["buddy_theme"] } else { $cfg_now["widget_theme"] }
            $this.BackColor = if ($n -eq $cur_now) { [System.Drawing.Color]::FromArgb(40,80,200,80) } else { [System.Drawing.Color]::FromArgb(0,0,0,0) }
        })
        foreach ($c in $r.Controls) {
            $c.Add_MouseEnter({ $this.Parent.BackColor = [System.Drawing.Color]::FromArgb(45,255,255,255) })
            $c.Add_MouseLeave({
                $n = $this.Parent.Tag
                $cfg_now = Read-WidgetConfig
                $cur_now = if ($script:themeTarget -eq "eq") { $cfg_now["eq_theme"] } elseif ($script:themeTarget -eq "buddy") { $cfg_now["buddy_theme"] } else { $cfg_now["widget_theme"] }
                $this.Parent.BackColor = if ($n -eq $cur_now) { [System.Drawing.Color]::FromArgb(40,80,200,80) } else { [System.Drawing.Color]::FromArgb(0,0,0,0) }
            })
        }

        $clickAction = {
            $script:selectedTheme = $this.Tag
            $this.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
            $this.FindForm().Close()
        }
        $r.Add_Click($clickAction)
        foreach ($c in $r.Controls) { $c.Add_Click($clickAction) }

        $form.Controls.Add($r)
        $y += $rowH
    }

    $cancel = New-Object System.Windows.Forms.Label
    $cancel.Text      = "Cancel"
    $cancel.ForeColor = $clrSub
    $cancel.Font      = $fontSmall
    $cancel.Location  = New-Object System.Drawing.Point(0, $y)
    $cancel.Size      = New-Object System.Drawing.Size(380, 30)
    $cancel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $cancel.BackColor = [System.Drawing.Color]::Transparent
    $cancel.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $cancel.Add_MouseEnter({ $this.ForeColor = $clrText })
    $cancel.Add_MouseLeave({ $this.ForeColor = $clrSub })
    $cancel.Add_Click({ $this.FindForm().Close() })
    $form.Controls.Add($cancel)

    # Store target for MouseLeave closures
    $script:themeTarget = $target

    # Close when clicking elsewhere (like the main menu), so pickers can't stack
    $form.Add_Deactivate({ if (-not $this.IsDisposed) { $this.Close() } })

    if ($form.ShowDialog() -eq "OK" -and $script:selectedTheme) {
        $cfg = Read-WidgetConfig
        if ($isEq) { $cfg["eq_theme"] = $script:selectedTheme }
        elseif ($target -eq "buddy") { $cfg["buddy_theme"] = $script:selectedTheme }
        else { $cfg["widget_theme"] = $script:selectedTheme }
        Write-WidgetConfig $cfg
        Log "Theme [$target] set to: $($script:selectedTheme)"

        # No server restart needed: server.js resolves the theme fresh on every
        # HTTP request, so the new theme is served on the next OBS source reload.
        # Just reload the relevant browser source in OBS to see the change.
    }
}

# ── Device picker ─────────────────────────────────────────────────────────────
function Show-DevicePicker {
    $tmp = Join-Path $env:TEMP "eq_list.py"
    $out = Join-Path $env:TEMP "eq_devs.json"
@'
import json,sys
try:
    import pyaudiowpatch as pyaudio
    p=pyaudio.PyAudio()
    wasapi=p.get_host_api_info_by_type(pyaudio.paWASAPI)
    d=[]
    for i in range(wasapi["deviceCount"]):
        dev=p.get_device_info_by_host_api_device_index(wasapi["index"],i)
        if dev["maxOutputChannels"]>0:
            d.append({"name":dev["name"],"index":dev["index"]})
    p.terminate()
    json.dump(d,open(sys.argv[1],"w"))
except Exception as e:
    json.dump([],open(sys.argv[1],"w"))
'@ | Set-Content $tmp -Encoding UTF8
    Start-Process -FilePath $PythonExe -ArgumentList "`"$tmp`" `"$out`"" -Wait -WindowStyle Hidden

    $devs = if(Test-Path $out){Get-Content $out -Raw|ConvertFrom-Json}else{@()}
    if (!$devs -or $devs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No WASAPI output devices found.","Music OBS Widget","OK","Warning")|Out-Null
        return
    }

    $rowH = 44
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.BackColor       = $clrBg
    $form.Width           = 380
    $form.Height          = 108 + $devs.Count * $rowH
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    Set-Rounded $form 16
    Enable-Acrylic $form

    $t1 = New-Object System.Windows.Forms.Label
    $t1.Text=$t1.Text="Select capture device"; $t1.ForeColor=$clrText; $t1.Font=$fontBold
    $t1.Location=New-Object System.Drawing.Point(20,16); $t1.Size=New-Object System.Drawing.Size(340,26)
    $t1.BackColor=[System.Drawing.Color]::Transparent; $form.Controls.Add($t1)

    $t2 = New-Object System.Windows.Forms.Label
    $t2.Text="Choose the audio device to capture for the equalizer:"
    $t2.ForeColor=$clrSub; $t2.Font=$fontSmall
    $t2.Location=New-Object System.Drawing.Point(20,44); $t2.Size=New-Object System.Drawing.Size(340,20)
    $t2.BackColor=[System.Drawing.Color]::Transparent; $form.Controls.Add($t2)

    $sp = New-Object System.Windows.Forms.Panel
    $sp.Size=New-Object System.Drawing.Size(340,1); $sp.Location=New-Object System.Drawing.Point(20,70)
    $sp.BackColor=$clrSep; $form.Controls.Add($sp)

    $y = 78; $sel = $null

    # Read current selected device from config
    $configPath = Join-Path $ScriptDir "eq_config.json"
    $currentDevice = ""
    if (Test-Path $configPath) {
        try { $currentDevice = (Get-Content $configPath -Raw | ConvertFrom-Json).device_name } catch {}
    }
    $script:currentDevice = $currentDevice

    foreach ($dev in $devs) {
        $isSelected = $dev.name -eq $currentDevice
        $r = New-Object System.Windows.Forms.Panel
        $r.Size=New-Object System.Drawing.Size(380,$rowH); $r.Location=New-Object System.Drawing.Point(0,$y)
        $r.BackColor=if($isSelected){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)}
        $r.Cursor=[System.Windows.Forms.Cursors]::Hand; $r.Tag=$dev.name

        $l = New-Object System.Windows.Forms.Label
        $l.Text=$dev.name; $l.Font=$fontMain
        $l.ForeColor=if($isSelected){[System.Drawing.Color]::FromArgb(120,220,120)}else{$clrText}
        $l.Location=New-Object System.Drawing.Point(20,12); $l.Size=New-Object System.Drawing.Size(260,22)
        $l.BackColor=[System.Drawing.Color]::Transparent; $l.Tag=$dev.name
        $r.Controls.Add($l)

        # Checkmark for selected device
        if ($isSelected) {
            $tick = New-Object System.Windows.Forms.Label
            $tick.Text = "selected"
            $tick.ForeColor = [System.Drawing.Color]::FromArgb(120,220,120)
            $tick.Font = $fontMain
            $tick.Location = New-Object System.Drawing.Point(300, 12)
            $tick.Size = New-Object System.Drawing.Size(60, 22)
            $tick.BackColor = [System.Drawing.Color]::Transparent
            $tick.Tag = $dev.name
            $r.Controls.Add($tick)
        }

        $r.Add_MouseEnter({ $this.BackColor=[System.Drawing.Color]::FromArgb(45,255,255,255) })
        $r.Add_MouseLeave({
            $n=$this.Tag
            $sel_now = $script:currentDevice
            $this.BackColor=if($n -eq $sel_now){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)}
        })
        foreach ($c in $r.Controls) {
            $c.Add_MouseEnter({ $this.Parent.BackColor=[System.Drawing.Color]::FromArgb(45,255,255,255) })
            $c.Add_MouseLeave({
                $n=$this.Parent.Tag
                $sel_now = $script:currentDevice
                $this.Parent.BackColor=if($n -eq $sel_now){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)}
            })
        }

        $clickAction = {
            $script:sel = $this.Tag
            $this.FindForm().DialogResult=[System.Windows.Forms.DialogResult]::OK
            $this.FindForm().Close()
        }
        $r.Add_Click($clickAction)
        foreach ($c in $r.Controls) { $c.Add_Click($clickAction) }
        $form.Controls.Add($r); $y += $rowH
    }

    $cancel = New-Object System.Windows.Forms.Label
    $cancel.Text="Cancel"; $cancel.ForeColor=$clrSub; $cancel.Font=$fontSmall
    $cancel.Location=New-Object System.Drawing.Point(0,$y); $cancel.Size=New-Object System.Drawing.Size(380,30)
    $cancel.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $cancel.BackColor=[System.Drawing.Color]::Transparent; $cancel.Cursor=[System.Windows.Forms.Cursors]::Hand
    $cancel.Add_MouseEnter({$this.ForeColor=$clrText}); $cancel.Add_MouseLeave({$this.ForeColor=$clrSub})
    $cancel.Add_Click({$this.FindForm().Close()})
    $form.Controls.Add($cancel)

    # Close when clicking elsewhere, so pickers can't stack
    $form.Add_Deactivate({ if (-not $this.IsDisposed) { $this.Close() } })

    if ($form.ShowDialog() -eq "OK" -and $script:sel) {
        $eqJson = "{`"device_name`": `"$($script:sel)`"}"
        [System.IO.File]::WriteAllText((Join-Path $ScriptDir "eq_config.json"), $eqJson, (New-Object System.Text.UTF8Encoding $false))
        Log "Device: $($script:sel)"
        if (Get-IsRunning $eqProcess) { Stop-Eq|Out-Null; Start-Sleep -ms 500; Start-Eq|Out-Null }
    }
}

# ── Music source picker ───────────────────────────────────────────────────────
function Restart-Smtc {
    # Restart only the SMTC reader so a new source app takes effect
    if (-not (Get-IsRunning $script:serverProcess)) { return }
    Kill-Tree $script:smtcProcess; Kill-Stray "smtc_reader.py"; $script:smtcProcess = $null
    Start-Sleep -Milliseconds 300
    if (Test-Path $SmtcScript) {
        $script:smtcProcess = Start-Process -FilePath $PythonExe `
            -ArgumentList "`"$SmtcScript`"" -WorkingDirectory $ScriptDir -PassThru -WindowStyle Hidden
        Log "SMTC restarted (source changed)"
    }
}

function Show-SourcePicker {
    if (!(Test-Path $SmtcScript)) {
        [System.Windows.Forms.MessageBox]::Show("smtc_reader.py not found.","Music OBS Widget","OK","Warning")|Out-Null
        return
    }
    $out = Join-Path $env:TEMP "music_sources.json"
    if (Test-Path $out) { Remove-Item $out -Force -EA SilentlyContinue }
    Start-Process -FilePath $PythonExe -ArgumentList "`"$SmtcScript`" --list `"$out`"" `
        -WorkingDirectory $ScriptDir -Wait -WindowStyle Hidden

    $srcs = @()
    if (Test-Path $out) { try { $srcs = @(Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
    $script:srcAll = $srcs

    $current = ""
    try { $current = (Read-WidgetConfig)["source_app_id"] } catch {}
    $script:srcCurrent = $current

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.BackColor       = $clrBg
    $form.Width           = 380
    $form.Height          = 380
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    Set-Rounded $form 16

    $t1 = New-Object System.Windows.Forms.Label
    $t1.Text="Select music source"; $t1.ForeColor=$clrText; $t1.Font=$fontBold
    $t1.Location=New-Object System.Drawing.Point(20,16); $t1.Size=New-Object System.Drawing.Size(340,26)
    $t1.BackColor=[System.Drawing.Color]::Transparent; $form.Controls.Add($t1)

    $t2 = New-Object System.Windows.Forms.Label
    $t2.Text="Windows exposes one app at a time. Pick or type the app to lock to:"
    $t2.ForeColor=$clrSub; $t2.Font=$fontSmall
    $t2.Location=New-Object System.Drawing.Point(20,44); $t2.Size=New-Object System.Drawing.Size(340,32)
    $t2.BackColor=[System.Drawing.Color]::Transparent; $form.Controls.Add($t2)

    # Auto row
    $autoRow = New-Object System.Windows.Forms.Panel
    $autoRow.Size=New-Object System.Drawing.Size(380,38); $autoRow.Location=New-Object System.Drawing.Point(0,80)
    $autoRow.BackColor=if($current -eq ""){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)}
    $autoRow.Cursor=[System.Windows.Forms.Cursors]::Hand
    $autoLab = New-Object System.Windows.Forms.Label
    $autoLab.Text="Auto (current app)"; $autoLab.Font=$fontMain
    $autoLab.ForeColor=if($current -eq ""){[System.Drawing.Color]::FromArgb(120,220,120)}else{$clrText}
    $autoLab.Location=New-Object System.Drawing.Point(20,8); $autoLab.Size=New-Object System.Drawing.Size(330,20)
    $autoLab.BackColor=[System.Drawing.Color]::Transparent; $autoRow.Controls.Add($autoLab)
    $autoCommit = {
        $script:srcSel=""; $script:srcSelected=$true
        $this.FindForm().DialogResult=[System.Windows.Forms.DialogResult]::OK
        $this.FindForm().Close()
    }
    $autoRow.Add_Click($autoCommit); $autoLab.Add_Click($autoCommit)
    $autoRow.Add_MouseEnter({ $this.BackColor=[System.Drawing.Color]::FromArgb(45,255,255,255) })
    $autoRow.Add_MouseLeave({ $this.BackColor=if($script:srcCurrent -eq ""){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)} })
    $form.Controls.Add($autoRow)

    # Search / free-text entry
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location=New-Object System.Drawing.Point(20,128); $search.Size=New-Object System.Drawing.Size(280,24)
    $search.BackColor=[System.Drawing.Color]::FromArgb(35,35,35); $search.ForeColor=$clrText
    $search.BorderStyle=[System.Windows.Forms.BorderStyle]::FixedSingle; $search.Font=$fontMain
    if ($current) { $search.Text = [string]$current }
    $form.Controls.Add($search)
    $script:srcSearchBox = $search

    $setBtn = New-Object System.Windows.Forms.Label
    $setBtn.Text="Set"; $setBtn.Font=$fontMain; $setBtn.ForeColor=[System.Drawing.Color]::FromArgb(120,220,120)
    $setBtn.Location=New-Object System.Drawing.Point(310,128); $setBtn.Size=New-Object System.Drawing.Size(50,24)
    $setBtn.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $setBtn.BackColor=[System.Drawing.Color]::FromArgb(40,80,200,80); $setBtn.Cursor=[System.Windows.Forms.Cursors]::Hand
    $commitTyped = {
        $v = ([string]$script:srcSearchBox.Text).Trim().ToLower()
        $script:srcSel=$v; $script:srcSelected=$true
        $this.FindForm().DialogResult=[System.Windows.Forms.DialogResult]::OK
        $this.FindForm().Close()
    }
    $setBtn.Add_Click($commitTyped)
    $form.Controls.Add($setBtn)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text="Detected now (click to choose):"; $hint.ForeColor=$clrSub; $hint.Font=$fontSmall
    $hint.Location=New-Object System.Drawing.Point(20,160); $hint.Size=New-Object System.Drawing.Size(340,18)
    $hint.BackColor=[System.Drawing.Color]::Transparent; $form.Controls.Add($hint)

    $listPanel = New-Object System.Windows.Forms.Panel
    $listPanel.Location=New-Object System.Drawing.Point(10,180); $listPanel.Size=New-Object System.Drawing.Size(360,150)
    $listPanel.BackColor=[System.Drawing.Color]::FromArgb(0,0,0,0); $listPanel.AutoScroll=$true
    $form.Controls.Add($listPanel)
    $script:srcListPanel = $listPanel

    $script:srcRefresh = {
        param($filter)
        $p = $script:srcListPanel
        $p.Controls.Clear()
        $f = ([string]$filter).Trim().ToLower()
        $yy = 0
        foreach ($s in $script:srcAll) {
            $nm = [string]$s.name; $idk = [string]$s.id
            if ($f -and -not (($nm.ToLower().Contains($f)) -or ($idk.ToLower().Contains($f)))) { continue }
            $row = New-Object System.Windows.Forms.Panel
            $row.Size=New-Object System.Drawing.Size(340,40); $row.Location=New-Object System.Drawing.Point(0,$yy)
            $isSel = ($idk -eq $script:srcCurrent)
            $row.BackColor=if($isSel){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)}
            $row.Cursor=[System.Windows.Forms.Cursors]::Hand; $row.Tag=$idk
            $nl = New-Object System.Windows.Forms.Label
            $nl.Text=$nm; $nl.Font=$fontMain; $nl.ForeColor=if($isSel){[System.Drawing.Color]::FromArgb(120,220,120)}else{$clrText}
            $nl.Location=New-Object System.Drawing.Point(14,3); $nl.Size=New-Object System.Drawing.Size(320,18)
            $nl.BackColor=[System.Drawing.Color]::Transparent; $nl.Tag=$idk; $row.Controls.Add($nl)
            $sub=""
            if ($s.artist -and $s.title) { $sub="$($s.artist) - $($s.title)" } elseif ($s.title) { $sub="$($s.title)" }
            if ($sub) {
                $sl = New-Object System.Windows.Forms.Label
                $sl.Text=$sub; $sl.Font=$fontSmall; $sl.ForeColor=$clrSub
                $sl.Location=New-Object System.Drawing.Point(14,21); $sl.Size=New-Object System.Drawing.Size(320,16)
                $sl.BackColor=[System.Drawing.Color]::Transparent; $sl.Tag=$idk; $row.Controls.Add($sl)
            }
            $rowCommit = {
                $script:srcSel=[string]$this.Tag; $script:srcSelected=$true
                $this.FindForm().DialogResult=[System.Windows.Forms.DialogResult]::OK
                $this.FindForm().Close()
            }
            $row.Add_Click($rowCommit)
            foreach ($c in $row.Controls) { $c.Add_Click($rowCommit) }
            $row.Add_MouseEnter({ $this.BackColor=[System.Drawing.Color]::FromArgb(45,255,255,255) })
            $row.Add_MouseLeave({ $n=$this.Tag; $this.BackColor=if($n -eq $script:srcCurrent){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)} })
            foreach ($c in $row.Controls) {
                $c.Add_MouseEnter({ $this.Parent.BackColor=[System.Drawing.Color]::FromArgb(45,255,255,255) })
                $c.Add_MouseLeave({ $n=$this.Parent.Tag; $this.Parent.BackColor=if($n -eq $script:srcCurrent){[System.Drawing.Color]::FromArgb(40,80,200,80)}else{[System.Drawing.Color]::FromArgb(0,0,0,0)} })
            }
            $p.Controls.Add($row)
            $yy += 44
        }
        if ($p.Controls.Count -eq 0) {
            $none = New-Object System.Windows.Forms.Label
            $none.Text="No matching app is sending media right now."
            $none.ForeColor=$clrSub; $none.Font=$fontSmall
            $none.Location=New-Object System.Drawing.Point(14,6); $none.Size=New-Object System.Drawing.Size(330,32)
            $none.BackColor=[System.Drawing.Color]::Transparent
            $p.Controls.Add($none)
        }
    }
    & $script:srcRefresh ""

    $search.Add_TextChanged({ & $script:srcRefresh $this.Text })
    $search.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress=$true
            $v=([string]$this.Text).Trim().ToLower()
            $script:srcSel=$v; $script:srcSelected=$true
            $this.FindForm().DialogResult=[System.Windows.Forms.DialogResult]::OK
            $this.FindForm().Close()
        }
    })

    $cancel = New-Object System.Windows.Forms.Label
    $cancel.Text="Cancel"; $cancel.ForeColor=$clrSub; $cancel.Font=$fontSmall
    $cancel.Location=New-Object System.Drawing.Point(0,338); $cancel.Size=New-Object System.Drawing.Size(380,30)
    $cancel.TextAlign=[System.Drawing.ContentAlignment]::MiddleCenter
    $cancel.BackColor=[System.Drawing.Color]::Transparent; $cancel.Cursor=[System.Windows.Forms.Cursors]::Hand
    $cancel.Add_MouseEnter({$this.ForeColor=$clrText}); $cancel.Add_MouseLeave({$this.ForeColor=$clrSub})
    $cancel.Add_Click({$this.FindForm().Close()})
    $form.Controls.Add($cancel)

    # Close when clicking elsewhere, so pickers can't stack
    $form.Add_Deactivate({ if (-not $this.IsDisposed) { $this.Close() } })

    $script:srcSelected = $false
    if ($form.ShowDialog() -eq "OK" -and $script:srcSelected) {
        $cfg = Read-WidgetConfig
        $cfg["source_app_id"] = $script:srcSel
        Write-WidgetConfig $cfg
        $shown = if ($script:srcSel) { $script:srcSel } else { "auto" }
        Log "Music source: $shown"
        Restart-Smtc
    }
}

# ── Tray events ───────────────────────────────────────────────────────────────
$tray.Add_MouseClick({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left -or
        $_.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        Show-Menu
    }
})

# ── HTTP listener ─────────────────────────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$TrayPort/")
$listener.Start()
Log "HTTP on $TrayPort. Tray ready."

# Synchronized queue: background thread receives HTTP requests and enqueues them.
# UI-thread timer drains the queue — all functions and $script:* state are accessible there.
$httpQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

$asyncScript = {
    while ($listener.IsListening) {
        try {
            $ctx = $listener.GetContext()
            $httpQueue.Enqueue($ctx)
        } catch {}
    }
}

$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $rs.Open()
$rs.SessionStateProxy.SetVariable("listener",  $listener)
$rs.SessionStateProxy.SetVariable("httpQueue", $httpQueue)
$ps2 = [System.Management.Automation.PowerShell]::Create(); $ps2.Runspace = $rs
$ps2.AddScript($asyncScript) | Out-Null; $ps2.BeginInvoke() | Out-Null

# UI-thread timer — drains the queue every 200ms in main runspace where all functions live
$httpTimer = New-Object System.Windows.Forms.Timer
$httpTimer.Interval = 200
$httpTimer.Add_Tick({
    $ctx = $null
    while ($httpQueue.TryDequeue([ref]$ctx)) {
        try {
            $resp = $ctx.Response
            $resp.Headers.Add("Access-Control-Allow-Origin","*")
            $resp.ContentType = "application/json"
            $r = switch ($ctx.Request.Url.AbsolutePath) {
                "/toggle"      { if ((Get-Status) -eq "running") { Stop-Widget } else { Start-Widget } }
                "/start"       { Start-Widget }   "/stop"         { Stop-Widget }
                "/status"      { Get-Status }     "/eq/start"     { Start-Eq }
                "/eq/stop"     { Stop-Eq }        "/eq/status"    { Get-EqStatus }
                "/buddy/start" { Start-Buddy }    "/buddy/stop"   { Stop-Buddy }
                "/buddy/status"{ Get-BuddyStatus }
                default        { "unknown" }
            }
            $b = [System.Text.Encoding]::UTF8.GetBytes("{`"status`":`"$r`"}")
            $resp.ContentLength64 = $b.Length
            $resp.OutputStream.Write($b, 0, $b.Length)
            $resp.OutputStream.Close()
        } catch {}
    }

    # Keep the tray icon + tooltip in sync with the real server state, even if it
    # was started/stopped via HTTP or died unexpectedly. Only refresh on change.
    $running = Get-IsRunning $script:serverProcess
    if ($script:lastTrayState -ne $running) {
        $script:lastTrayState = $running
        Set-TrayIcon $running
    }
})
$httpTimer.Start()

[System.Windows.Forms.Application]::Run()
$httpTimer.Stop()
$listener.Stop(); $tray.Visible=$false
