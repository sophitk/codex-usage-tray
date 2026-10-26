[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Json,
    [int]$RefreshSeconds = 30,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-CodexUsageSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$HomePath,
        [int]$RecentFileCount = 50,
        [int]$TailLineCount = 500
    )

    $sessionRoot = Join-Path $HomePath 'sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
        throw "Codex sessions folder was not found: $sessionRoot"
    }

    # Codex stores sessions as sessions\yyyy\MM\dd. Avoid recursively walking
    # years of history on every tray refresh; recent folders also catch tasks
    # that have remained active across multiple days.
    $candidateFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    for ($daysAgo = 0; $daysAgo -lt 30; $daysAgo++) {
        $date = [DateTime]::Today.AddDays(-$daysAgo)
        $dayFolder = Join-Path (Join-Path (Join-Path $sessionRoot $date.ToString('yyyy')) $date.ToString('MM')) $date.ToString('dd')
        if (-not (Test-Path -LiteralPath $dayFolder -PathType Container)) { continue }
        foreach ($candidate in (Get-ChildItem -LiteralPath $dayFolder -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $candidateFiles.Add($candidate)
        }
    }
    $files = @($candidateFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $RecentFileCount)

    $best = $null
    foreach ($file in $files) {
        $lines = @(Get-Content -LiteralPath $file.FullName -Tail $TailLineCount -ErrorAction SilentlyContinue)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $line = $lines[$index]
            if ($line -notmatch '"rate_limits"') { continue }

            try {
                $event = $line | ConvertFrom-Json
                if ($event.type -ne 'event_msg' -or $event.payload.type -ne 'token_count') { continue }
                if ($null -eq $event.payload.rate_limits -or $null -eq $event.payload.rate_limits.primary) { continue }

                $observedAt = [DateTimeOffset]::Parse([string]$event.timestamp)
                if ($null -eq $best -or $observedAt -gt $best.ObservedAt) {
                    $limits = $event.payload.rate_limits
                    $primary = $limits.primary
                    $secondary = $limits.secondary
                    $best = [pscustomobject]@{
                        ObservedAt = $observedAt
                        UsedPercent = [double]$primary.used_percent
                        RemainingPercent = [math]::Max(0, [math]::Min(100, 100 - [double]$primary.used_percent))
                        WindowMinutes = [int]$primary.window_minutes
                        ResetsAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$primary.resets_at)
                        SecondaryUsedPercent = if ($null -ne $secondary) { [double]$secondary.used_percent } else { $null }
                        SecondaryRemainingPercent = if ($null -ne $secondary) { [math]::Max(0, [math]::Min(100, 100 - [double]$secondary.used_percent)) } else { $null }
                        SecondaryWindowMinutes = if ($null -ne $secondary) { [int]$secondary.window_minutes } else { $null }
                        SecondaryResetsAt = if ($null -ne $secondary) { [DateTimeOffset]::FromUnixTimeSeconds([long]$secondary.resets_at) } else { $null }
                        PlanType = [string]$limits.plan_type
                        SourceFile = $file.FullName
                    }
                }
                # Continue checking candidate event timestamps.
            }
            catch {
                continue
            }
        }
    }

    if ($null -eq $best) {
        throw 'No Codex usage event was found. Use Codex once, then refresh the widget.'
    }
    return $best
}

function Convert-WindowLabel {
    param([int]$Minutes)
    if ($Minutes -ge 10080 -and $Minutes % 10080 -eq 0) { return ('{0}-week window' -f ($Minutes / 10080)) }
    if ($Minutes -ge 1440 -and $Minutes % 1440 -eq 0) { return ('{0}-day window' -f ($Minutes / 1440)) }
    if ($Minutes -ge 60 -and $Minutes % 60 -eq 0) { return ('{0}-hour window' -f ($Minutes / 60)) }
    return "$Minutes-minute window"
}

if ($Once) {
    try {
        $snapshot = Get-CodexUsageSnapshot -HomePath $CodexHome
        if ($Json) {
            $snapshot | ConvertTo-Json -Depth 4
        }
        else {
            '{0:N0}% remaining | resets {1} | observed {2}' -f $snapshot.RemainingPercent, $snapshot.ResetsAt.ToLocalTime().ToString('g'), $snapshot.ObservedAt.ToLocalTime().ToString('g')
        }
        exit 0
    }
    catch {
        if ($Json) {
            [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json
        }
        else {
            Write-Error $_.Exception.Message
        }
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeIcon {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptPath = $MyInvocation.MyCommand.Path
$startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupName = 'CodexUsageTray'

function Test-StartsWithWindows {
    try { return $null -ne (Get-ItemPropertyValue -Path $startupKey -Name $startupName -ErrorAction Stop) }
    catch { return $false }
}

function Set-StartsWithWindows {
    param([bool]$Enabled)
    if ($Enabled) {
        $command = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
        New-Item -Path $startupKey -Force | Out-Null
        New-ItemProperty -Path $startupKey -Name $startupName -Value $command -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -Path $startupKey -Name $startupName -ErrorAction SilentlyContinue
    }
}

function New-UsageIcon {
    param([Nullable[double]]$Remaining, [bool]$HasError = $false)

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear([System.Drawing.Color]::Transparent)

    if ($HasError) { $fill = [System.Drawing.Color]::FromArgb(225, 73, 73) }
    elseif ($Remaining -ge 50) { $fill = [System.Drawing.Color]::FromArgb(24, 174, 122) }
    elseif ($Remaining -ge 20) { $fill = [System.Drawing.Color]::FromArgb(238, 164, 44) }
    else { $fill = [System.Drawing.Color]::FromArgb(225, 73, 73) }

    $brush = New-Object System.Drawing.SolidBrush $fill
    $graphics.FillEllipse($brush, 1, 1, 30, 30)
    $text = if ($HasError) { '!' } elseif ($Remaining -ge 99.5) { '99+' } else { [math]::Round([double]$Remaining).ToString('0') }
    $fontSize = if ($text.Length -ge 3) { 9.0 } else { 12.0 }
    $font = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $graphics.DrawString($text, $font, $textBrush, [System.Drawing.RectangleF]::new(0, 0, 32, 31), $format)

    $hIcon = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon).Clone()
    [NativeIcon]::DestroyIcon($hIcon) | Out-Null
    $textBrush.Dispose(); $format.Dispose(); $font.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    return $icon
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Usage'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ShowInTaskbar = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ClientSize = New-Object System.Drawing.Size 340, 190
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 251)
$form.Font = New-Object System.Drawing.Font 'Segoe UI', 9

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'CODEX USAGE'
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(95, 101, 112)
$titleLabel.Font = New-Object System.Drawing.Font 'Segoe UI Semibold', 9
$titleLabel.SetBounds(20, 16, 200, 20)

$percentLabel = New-Object System.Windows.Forms.Label
$percentLabel.Text = '--% remaining'
$percentLabel.ForeColor = [System.Drawing.Color]::FromArgb(28, 31, 36)
$percentLabel.Font = New-Object System.Drawing.Font 'Segoe UI Semibold', 22
$percentLabel.SetBounds(18, 39, 300, 45)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Minimum = 0
$progress.Maximum = 100
$progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$progress.SetBounds(21, 91, 298, 14)

$windowLabel = New-Object System.Windows.Forms.Label
$windowLabel.Text = 'Waiting for local Codex data...'
$windowLabel.ForeColor = [System.Drawing.Color]::FromArgb(82, 88, 98)
$windowLabel.SetBounds(20, 116, 300, 20)

$resetLabel = New-Object System.Windows.Forms.Label
$resetLabel.Text = ''
$resetLabel.ForeColor = [System.Drawing.Color]::FromArgb(82, 88, 98)
$resetLabel.SetBounds(20, 139, 300, 20)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ''
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(126, 132, 142)
$statusLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 8
$statusLabel.SetBounds(20, 163, 300, 18)

$form.Controls.AddRange(@($titleLabel, $percentLabel, $progress, $windowLabel, $resetLabel, $statusLabel))

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('Open usage')
$refreshItem = $menu.Items.Add('Refresh now')
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$startupItem = $menu.Items.Add('Start with Windows')
$startupItem.CheckOnClick = $true
$startupItem.Checked = Test-StartsWithWindows
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$exitItem = $menu.Items.Add('Exit')

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Codex usage: loading...'
$tray.Icon = New-UsageIcon -Remaining $null -HasError $true
$form.Icon = $tray.Icon
$tray.Visible = $true
$tray.ContextMenuStrip = $menu

function Show-UsageWindow {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point ($area.Right - $form.Width - 12), ($area.Bottom - $form.Height - 12)
    $form.Show()
    $form.Activate()
}

function Update-UsageDisplay {
    try {
        $snapshot = Get-CodexUsageSnapshot -HomePath $CodexHome
        $remaining = [math]::Round($snapshot.RemainingPercent)
        $percentLabel.Text = "$remaining% remaining"
        $progress.Value = [int]$remaining
        $windowLabel.Text = Convert-WindowLabel $snapshot.WindowMinutes
        $resetLabel.Text = 'Resets {0}' -f $snapshot.ResetsAt.ToLocalTime().ToString('ddd, MMM d  HH:mm')
        $age = [DateTimeOffset]::Now - $snapshot.ObservedAt.ToLocalTime()
        $statusLabel.Text = if ($age.TotalMinutes -lt 2) { 'Updated just now from local Codex data' } else { 'Codex data observed {0} ago' -f $(if ($age.TotalHours -ge 1) { '{0:N0}h' -f $age.TotalHours } else { '{0:N0}m' -f $age.TotalMinutes }) }

        $oldIcon = $tray.Icon
        $newIcon = New-UsageIcon -Remaining $remaining
        $tray.Icon = $newIcon
        $form.Icon = $newIcon
        if ($null -ne $oldIcon) { $oldIcon.Dispose() }
        $tip = 'Codex: {0}% remaining - resets {1}' -f $remaining, $snapshot.ResetsAt.ToLocalTime().ToString('g')
        $tray.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))
    }
    catch {
        $percentLabel.Text = 'Usage unavailable'
        $progress.Value = 0
        $windowLabel.Text = $_.Exception.Message
        $resetLabel.Text = 'Open Codex and complete one response, then refresh.'
        $statusLabel.Text = ''
        $oldIcon = $tray.Icon
        $newIcon = New-UsageIcon -Remaining $null -HasError $true
        $tray.Icon = $newIcon
        $form.Icon = $newIcon
        if ($null -ne $oldIcon) { $oldIcon.Dispose() }
        $tray.Text = 'Codex usage unavailable'
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [math]::Max(10, $RefreshSeconds) * 1000
$timer.Add_Tick({ Update-UsageDisplay })
$timer.Start()

$tray.Add_MouseClick({ param($sender, $eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { if ($form.Visible) { $form.Hide() } else { Show-UsageWindow } } })
$openItem.Add_Click({ Show-UsageWindow })
$refreshItem.Add_Click({ Update-UsageDisplay })
$startupItem.Add_Click({
    try { Set-StartsWithWindows -Enabled $startupItem.Checked }
    catch { $startupItem.Checked = -not $startupItem.Checked; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Codex Usage', 'OK', 'Error') | Out-Null }
})
$exitItem.Add_Click({ $form.Close() })
$form.Add_FormClosing({ $timer.Stop(); $tray.Visible = $false })

Update-UsageDisplay
[System.Windows.Forms.Application]::Run($form)
$timer.Dispose(); $tray.Dispose(); $form.Dispose()
