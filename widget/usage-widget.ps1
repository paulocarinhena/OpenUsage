<#
  Floating Claude / Codex / Cursor usage widget.
  Plain PowerShell + WPF (built into Windows): nothing to download.
  Data comes from ..\scripts\usage-json.ts, run with Node (>= 22.6).

  Run:  double-click widget\usage-widget.vbs
#>
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$RefreshMinutes = 5
$StateDir = Join-Path $env:APPDATA 'usage-widget'
$StatePath = Join-Path $StateDir 'widget.json'
$Icons = @{ claude = [string][char]0x273B; codex = [string][char]0x25CE; cursor = [string][char]0x2B21; 'opencode-go' = [string][char]0x25A3 }

# ---- single instance ----------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\usage-widget')
# A second launch asks the running instance to show itself instead of silently exiting.
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\usage-widget-show')
if (-not $mutex.WaitOne(0)) { $showEvent.Set() | Out-Null; exit }

# ---- persisted state ----------------------------------------------------------
function Get-State {
  try { return Get-Content $StatePath -Raw | ConvertFrom-Json } catch { return [pscustomobject]@{} }
}
function Set-State([hashtable]$patch) {
  $s = @{}
  (Get-State).PSObject.Properties | ForEach-Object { $s[$_.Name] = $_.Value }
  foreach ($k in $patch.Keys) { $s[$k] = $patch[$k] }
  New-Item -ItemType Directory -Force $StateDir | Out-Null
  $s | ConvertTo-Json | Set-Content -Encoding UTF8 $StatePath
}
$state = Get-State
$script:display = if ($state.display) { $state.display } else { 'used' }

# ---- theme (follows Windows light/dark) ---------------------------------------
$light = $false
try { $light = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme) -eq 1 } catch {}
$C = if ($light) {
  @{ Bg = '#FBFAF8'; Border = '#E2DDD7'; Divider = '#ECE8E3'; Text = '#1F1C1A'; Muted = '#857D76'; Warn = '#C46D12'; Error = '#C9362D'; Track = '#E4DED7'; Hover = '#F1EDE8'; Card = '#F3F0EB'; CardBorder = '#E8E3DD' }
} else {
  @{ Bg = '#1C1A19'; Border = '#34302D'; Divider = '#2C2926'; Text = '#EBE7E2'; Muted = '#8D8680'; Warn = '#E8953F'; Error = '#E5584F'; Track = '#35302C'; Hover = '#2A2725'; Card = '#242120'; CardBorder = '#2E2A27' }
}
function Brush([string]$hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

# ---- window -------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenUsage" Width="320" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" ShowActivated="False"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="$($C.Text)">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="6,2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Hover)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="8" Background="$($C.Bg)" BorderBrush="$($C.Border)" BorderThickness="1" CornerRadius="12" Padding="14,10,14,10">
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35"/></Border.Effect>
    <StackPanel>
      <DockPanel x:Name="Header" Background="Transparent" Margin="0,0,0,8">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="ModeBtn" Style="{StaticResource Btn}" ToolTip="Used / left">Used</Button>
          <Button x:Name="RefreshBtn" Style="{StaticResource Btn}" ToolTip="Refresh">&#x27F3;</Button>
          <Button x:Name="HideBtn" Style="{StaticResource Btn}" ToolTip="Hide (tray icon brings it back)">&#x2715;</Button>
        </StackPanel>
        <TextBlock VerticalAlignment="Center" FontWeight="SemiBold">
          <Run Foreground="$($C.Muted)">&#x25F7;</Run> OpenUsage
        </TextBlock>
      </DockPanel>
      <Border Height="1" Background="$($C.Divider)" Margin="0,0,0,8"/>
      <StackPanel x:Name="List"/>
      <Border Height="1" Background="$($C.Divider)" Margin="0,10,0,6"/>
      <DockPanel>
        <TextBlock x:Name="ErrorText" DockPanel.Dock="Right" Foreground="$($C.Error)" FontSize="11.5"/>
        <TextBlock x:Name="Updated" Foreground="$($C.Muted)" FontSize="11.5"/>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
foreach ($n in 'Header', 'ModeBtn', 'RefreshBtn', 'HideBtn', 'List', 'Updated', 'ErrorText') { $ui[$n] = $win.FindName($n) }

$area = [System.Windows.SystemParameters]::WorkArea
$win.Left = if ($null -ne $state.x) { [double]$state.x } else { $area.Right - 330 }
$win.Top = if ($null -ne $state.y) { [double]$state.y } else { $area.Top + 16 }
$win.Topmost = if ($null -ne $state.topmost) { [bool]$state.topmost } else { $true }

# ---- formatting ---------------------------------------------------------------
function Level([double]$pct) { if ($pct -ge 80) { $C.Error } elseif ($pct -ge 50) { $C.Warn } else { $null } }

function Format-Reset($ms) {
  if (-not $ms) { return '' }
  $d = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime
  if ($d.Date -eq (Get-Date).Date) { return $d.ToString('t') }
  return $d.ToString('ddd, dd MMM') + ', ' + $d.ToString('t')
}

function Format-Ago($ms) {
  if (-not $ms) { return '' }
  $m = [math]::Round(((Get-Date) - [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime).TotalMinutes)
  if ($m -lt 1) { 'updated just now' } elseif ($m -lt 60) { "updated $m min ago" } else { "updated $([math]::Round($m / 60)) h ago" }
}

function New-Text([string]$text, $color, [double]$size = 13, [string]$weight = 'Normal') {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontSize = $size
  $t.FontWeight = $weight
  if ($color) { $t.Foreground = Brush $color }
  return $t
}

function New-Row($left, $right) {
  $row = New-Object System.Windows.Controls.DockPanel
  $row.Margin = '0,3,0,0'
  [System.Windows.Controls.DockPanel]::SetDock($right, 'Right')
  $row.Children.Add($right) | Out-Null
  $row.Children.Add($left) | Out-Null
  return $row
}

# ---- data ---------------------------------------------------------------------
# The last good result is cached on disk, so a restart (or a rate-limited first fetch) still shows numbers.
$CachePath = Join-Path $StateDir 'data.json'
$script:data = @()
$script:updatedAt = $null
try {
  $cache = Get-Content $CachePath -Raw | ConvertFrom-Json
  $script:data = @($cache.data)
  $script:updatedAt = $cache.updatedAt
} catch {}
$script:lastError = ''
$script:proc = $null

function Render {
  $ui.List.Children.Clear()
  if (-not $script:data.Count) {
    $msg = if ($script:proc) { 'Loading...' } else { 'No data' }
    $ui.List.Children.Add((New-Text $msg $C.Muted)) | Out-Null
  }
  $first = $true
  foreach ($u in $script:data) {
    # One card per provider so each block reads as a unit.
    $card = New-Object System.Windows.Controls.Border
    $card.Background = Brush $C.Card
    $card.BorderBrush = Brush $C.CardBorder
    $card.BorderThickness = 1
    $card.CornerRadius = 8
    $card.Padding = '11,9,11,10'
    if (-not $first) { $card.Margin = '0,8,0,0' }
    $first = $false
    $section = New-Object System.Windows.Controls.StackPanel
    $card.Child = $section

    $head = New-Object System.Windows.Controls.TextBlock
    $head.FontWeight = 'SemiBold'
    $head.FontSize = 13.5
    $head.Inlines.Add((New-Object System.Windows.Documents.Run ("$($Icons[$u.id])  ") -Property @{ Foreground = (Brush $C.Muted) }))
    $head.Inlines.Add((New-Object System.Windows.Documents.Run $u.name))
    $planBox = New-Object System.Windows.Controls.Border
    if ($u.plan) {
      $planBox.Background = Brush $C.Track
      $planBox.CornerRadius = 4
      $planBox.Padding = '6,1,6,1'
      $planBox.VerticalAlignment = 'Center'
      $planBox.Child = New-Text ([string]$u.plan).ToUpper() $C.Muted 10 'SemiBold'
    }
    $section.Children.Add((New-Row $head $planBox)) | Out-Null
    if ($u.account) {
      $acct = New-Text ([string]$u.account) $C.Muted 11.5
      $acct.Margin = '0,1,0,0'
      $acct.TextTrimming = 'CharacterEllipsis'
      $acct.ToolTip = [string]$u.account
      $section.Children.Add($acct) | Out-Null
    }

    $hasData = ($u.windows.Count + $u.extras.Count) -gt 0
    if ($u.error) {
      $t = if ($hasData) { "stale - $($u.error)" } else { $u.error }
      $errColor = if ($hasData) { $C.Warn } else { $C.Muted }
      $e = New-Text $t $errColor 12
      $e.TextWrapping = 'Wrap'
      $e.Margin = '0,6,0,0'
      $section.Children.Add($e) | Out-Null
    }

    $firstMetric = $true
    foreach ($w in $u.windows) {
      $pct = if ($script:display -eq 'used') { $w.usedPct } else { 100 - $w.usedPct }
      $lv = Level $w.usedPct
      $label = New-Object System.Windows.Controls.TextBlock
      $label.Inlines.Add((New-Object System.Windows.Documents.Run $w.label))
      $reset = Format-Reset $w.resetsAt
      if ($reset) { $label.Inlines.Add((New-Object System.Windows.Documents.Run "  $reset" -Property @{ Foreground = (Brush $C.Muted); FontSize = 12 })) }
      $label.TextTrimming = 'CharacterEllipsis'
      $valueColor = if ($lv) { $lv } else { $C.Text }
      $row = New-Row $label (New-Text ("{0}%" -f [math]::Round($pct)) $valueColor 13 'SemiBold')
      $row.Margin = if ($firstMetric) { '0,9,0,0' } else { '0,8,0,0' }
      $firstMetric = $false
      $section.Children.Add($row) | Out-Null

      $bar = New-Object System.Windows.Controls.ProgressBar
      $bar.Height = 4
      $bar.Margin = '0,5,0,0'
      $bar.Value = [math]::Max(0, [math]::Min(100, $w.usedPct))
      $bar.BorderThickness = 0
      $bar.Background = Brush $C.Track
      $bar.Foreground = Brush $(if ($lv) { $lv } else { $C.Muted })
      $section.Children.Add($bar) | Out-Null
    }
    foreach ($x in $u.extras) {
      $row = New-Row (New-Text $x.label $C.Muted 12.5) (New-Text $x.value $C.Text 12.5)
      $row.Margin = if ($firstMetric) { '0,9,0,0' } else { '0,8,0,0' }
      $firstMetric = $false
      $section.Children.Add($row) | Out-Null
    }
    $ui.List.Children.Add($card) | Out-Null
  }
  $ui.ModeBtn.Content = if ($script:display -eq 'used') { 'Used' } else { 'Left' }
  $ui.Updated.Text = if ($script:proc) { 'refreshing...' } else { Format-Ago $script:updatedAt }
  $ui.ErrorText.Text = $script:lastError
  Update-TrayText
}

function Start-Refresh {
  if ($script:proc) { return }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node'
  $psi.Arguments = '--experimental-strip-types --no-warnings "' + (Join-Path $Root 'scripts\usage-json.ts') + '"'
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  try {
    $script:proc = [System.Diagnostics.Process]::Start($psi)
    # Read asynchronously so a full pipe never blocks the child.
    $script:outTask = $script:proc.StandardOutput.ReadToEndAsync()
    $script:errTask = $script:proc.StandardError.ReadToEndAsync()
    $script:procStarted = Get-Date
  } catch {
    $script:proc = $null
    $script:lastError = 'node not found'
  }
  Render
}

function Complete-Refresh {
  $p = $script:proc
  if (-not $p) { return }
  if (-not $p.HasExited) {
    if (((Get-Date) - $script:procStarted).TotalSeconds -gt 60) { try { $p.Kill() } catch {} ; $script:lastError = 'timed out' ; $script:proc = $null ; Render }
    return
  }
  $script:proc = $null
  try {
    # Windows PowerShell's ConvertFrom-Json emits a JSON array as one object; ForEach-Object unrolls it.
    $fresh = @($script:outTask.Result | ConvertFrom-Json | ForEach-Object { $_ })
    # A transient provider failure keeps the last good numbers, flagged as stale.
    $prev = @{}
    foreach ($u in $script:data) { $prev[$u.id] = $u }
    $script:data = @(foreach ($u in $fresh) {
      if ($u.error -and $prev[$u.id] -and $prev[$u.id].windows.Count) {
        # Good results carry no "error" property, so add it rather than assign it.
        $old = $prev[$u.id].PSObject.Copy(); $old | Add-Member -Force NoteProperty error $u.error; $old
      } else { $u }
    })
    $script:updatedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $script:lastError = ''
    try {
      New-Item -ItemType Directory -Force $StateDir | Out-Null
      @{ updatedAt = $script:updatedAt; data = $script:data } | ConvertTo-Json -Depth 8 -Compress | Set-Content -Encoding UTF8 $CachePath
    } catch {}
  } catch {
    $script:lastError = 'refresh failed'
  }
  Render
}

# ---- tray ---------------------------------------------------------------------
$IconPath = Join-Path $PSScriptRoot 'openusage.ico'
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-Object System.Drawing.Icon $IconPath, ([System.Windows.Forms.SystemInformation]::SmallIconSize)
$tray.Text = 'OpenUsage'
$tray.Visible = $true

function Update-TrayText {
  $parts = foreach ($u in $script:data) {
    if ($u.windows.Count) { "{0} {1}%" -f $u.name, [math]::Round(($u.windows | Measure-Object usedPct -Maximum).Maximum) }
  }
  $text = if ($parts) { 'OpenUsage - ' + ($parts -join ' | ') } else { 'OpenUsage' }
  $tray.Text = $text.Substring(0, [math]::Min(63, $text.Length))
}

function Toggle-Window {
  if ($win.IsVisible) { $win.Hide(); Set-State @{ hidden = $true } }
  else { $win.Show(); Set-State @{ hidden = $false } }
}

function New-Shortcut([string]$path) {
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
  # Go through the .vbs launcher so no console window flashes.
  $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $lnk.Arguments = "`"$(Join-Path $PSScriptRoot 'usage-widget.vbs')`""
  $lnk.IconLocation = $IconPath
  $lnk.Description = 'OpenUsage'
  $lnk.Save()
}

# A menu item that creates or removes a shortcut.
function New-ShortcutItem([string]$text, [string]$path) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
  $item.Tag = $path
  $item.Checked = Test-Path $path
  $item.add_Click({
    param($s)
    if (Test-Path $s.Tag) { Remove-Item $s.Tag } else { New-Shortcut $s.Tag }
    $s.Checked = Test-Path $s.Tag
  })
  return $item
}

$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'usage-widget.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenUsage.lnk'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('Show / hide', $null, { Toggle-Window })
$null = $menu.Items.Add('Refresh', $null, { Start-Refresh })
$null = $menu.Items.Add('-')
$topItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Always on top'
$topItem.Checked = $win.Topmost
$topItem.add_Click({ $win.Topmost = -not $win.Topmost; $topItem.Checked = $win.Topmost; Set-State @{ topmost = $win.Topmost } })
$null = $menu.Items.Add($topItem)
$null = $menu.Items.Add((New-ShortcutItem 'Start with Windows' $startupLink))
$null = $menu.Items.Add((New-ShortcutItem 'Desktop shortcut' $desktopLink))
$null = $menu.Items.Add('-')
$null = $menu.Items.Add('Quit', $null, { $script:quitting = $true; $win.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Window } })

# ---- events -------------------------------------------------------------------
$ui.Header.add_MouseLeftButtonDown({ $win.DragMove(); Set-State @{ x = $win.Left; y = $win.Top } })
$ui.ModeBtn.add_Click({
  $script:display = if ($script:display -eq 'used') { 'remaining' } else { 'used' }
  Set-State @{ display = $script:display }
  Render
})
$ui.RefreshBtn.add_Click({ Start-Refresh })
$ui.HideBtn.add_Click({ Toggle-Window })
$win.add_Closing({ param($s, $e) if (-not $script:quitting) { $e.Cancel = $true; Toggle-Window } })
$win.add_Closed({ $tray.Visible = $false; $tray.Dispose(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

# Poll the child process and schedule refreshes on the UI thread.
$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(400)
$poll.add_Tick({
  if ($showEvent.WaitOne(0) -and -not $win.IsVisible) { Toggle-Window }
  Complete-Refresh
})
$poll.Start()
$tick = New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromMinutes($RefreshMinutes)
$tick.add_Tick({ Start-Refresh })
$tick.Start()
$ago = New-Object System.Windows.Threading.DispatcherTimer
$ago.Interval = [TimeSpan]::FromSeconds(30)
$ago.add_Tick({ if (-not $script:proc) { $ui.Updated.Text = Format-Ago $script:updatedAt } })
$ago.Start()

# Launching the widget always shows it; "hidden" only lasts for the running session.
$win.Show()
Set-State @{ hidden = $false }
Start-Refresh
[System.Windows.Threading.Dispatcher]::Run()
$mutex.ReleaseMutex()
