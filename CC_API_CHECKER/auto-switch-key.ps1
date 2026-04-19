# ================================================================
# Claude Code API Key Auto-Switcher
# 自动检测当前 key 额度，额度不足时切换到剩余额度最多的 key
#
# Usage:
#   .\auto-switch-key.ps1                 # 一次性检测并切换
#   .\auto-switch-key.ps1 -Current        # 查看当前 key 详细信息
#   .\auto-switch-key.ps1 -Name osr-p4_3  # 查询指定 key 详细信息
#   .\auto-switch-key.ps1 -Name -ALL      # 所有 key 详细信息（状态/额度/Token/模型明细）
#   .\auto-switch-key.ps1 -Status         # 所有 key 按剩余额度排名
#   .\auto-switch-key.ps1 -Dashboard      # 所有 key 每日消费概览
#   .\auto-switch-key.ps1 -Threshold 10   # 余量低于 $10 时自动切换
#   .\auto-switch-key.ps1 -Monitor -Interval 120  # 持续监控（120秒间隔）
#   .\auto-switch-key.ps1 -Background              # 后台监控（隐藏窗口）
#   .\auto-switch-key.ps1 -Stop                    # 停止后台监控
#   .\auto-switch-key.ps1 -DryRun         # 模拟运行，不实际切换（测试用）
# ================================================================
param(
    [switch]$Monitor,
    [int]$Interval = 300,
    [double]$Threshold = 5.0,
    [switch]$Status,
    [switch]$Dashboard,
    [switch]$Current,
    [string]$Name,
    [switch]$Background,
    [switch]$Stop,
    [switch]$DryRun,
    [switch]$Help
)

# ----------------------------------------------------------------
# TLS Security
# ----------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# ----------------------------------------------------------------
# Config
# ----------------------------------------------------------------
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "api-keys.json"
$API_BASE   = "https://osr.cc.sususu.cf"
$logFile    = Join-Path $scriptDir "switch-key.log"
$pidFile    = Join-Path $scriptDir "monitor.pid"

# ----------------------------------------------------------------
# Load API keys
# ----------------------------------------------------------------
if (-not (Test-Path $configPath)) {
    Write-Host ""
    WC "  [ERROR] 配置文件不存在: $configPath" Red
    WC '  请创建 api-keys.json，格式如下:' DarkGray
    WC '  [{ "Name": "key名称", "Key": "sk-xxx", "Dept": "部门", "Admin": "管理员" }]' DarkGray
    Write-Host ""
    exit 1
}
try {
    $API_KEYS = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host ""
    WC "  [ERROR] 配置文件解析失败: $($_.Exception.Message)" Red
    WC "  请检查 api-keys.json 是否为合法 JSON 格式" DarkGray
    Write-Host ""
    exit 1
}
if ($API_KEYS.Count -eq 0) {
    Write-Host ""
    WC "  [ERROR] 配置文件中没有 key" Red
    WC "  请在 api-keys.json 中添加至少一个 key 条目" DarkGray
    Write-Host ""
    exit 1
}

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
function WC {
    param([string]$Text, [string]$Color = "White", [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Text -ForegroundColor $Color }
}

function Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---- Windows Toast Notification (non-blocking) ----
# Reason: Monitor 模式下用户不会盯着终端，需要系统通知提醒
function Notify {
    param([string]$Title, [string]$Body, [string]$Level = "Warning")
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = switch ($Level) {
            "Error"   { [System.Windows.Forms.ToolTipIcon]::Error }
            "Info"    { [System.Windows.Forms.ToolTipIcon]::Info }
            default   { [System.Windows.Forms.ToolTipIcon]::Warning }
        }
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.ShowBalloonTip(10000, $Title, $Body, $icon)
        # Reason: 延迟清理避免通知还没显示就被销毁
        Start-Sleep -Milliseconds 500
        $notify.Dispose()
    } catch {}
}

# ---- GUI Key Selector Dialog (for Monitor mode) ----
# Reason: Monitor 模式后台运行时弹出深色主题 GUI 窗口让用户选择切换目标
function ShowKeySelectorDialog {
    param([array]$Candidates, [string]$CurrentKeyValue)

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    # -- Color palette --
    $bgColor      = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $panelColor   = [System.Drawing.Color]::FromArgb(45, 45, 45)
    $fgColor      = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $dimColor     = [System.Drawing.Color]::FromArgb(140, 140, 140)
    $accentGreen  = [System.Drawing.Color]::FromArgb(76, 175, 80)
    $accentYellow = [System.Drawing.Color]::FromArgb(255, 193, 7)
    $accentRed    = [System.Drawing.Color]::FromArgb(244, 67, 54)
    $accentBlue   = [System.Drawing.Color]::FromArgb(66, 165, 245)
    $btnHover     = [System.Drawing.Color]::FromArgb(60, 60, 60)

    $fontTitle = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
    $fontBody  = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $fontMono  = New-Object System.Drawing.Font("Consolas", 9.5)
    $fontBtn   = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)

    # -- Form --
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "API Key Switcher"
    $form.Size = New-Object System.Drawing.Size(580, 480)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.TopMost = $true
    $form.BackColor = $bgColor

    # -- Title --
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = [char]0x26A1 + " 额度不足，请选择切换目标"
    $lblTitle.ForeColor = $fgColor
    $lblTitle.Font = $fontTitle
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # -- Key list panel (OwnerDraw) --
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.DrawMode = "OwnerDrawFixed"
    $listBox.ItemHeight = 38
    $listBox.Location = New-Object System.Drawing.Point(20, 55)
    $listBox.Size = New-Object System.Drawing.Size(525, 310)
    $listBox.BackColor = $panelColor
    $listBox.ForeColor = $fgColor
    $listBox.BorderStyle = "None"
    $listBox.Font = $fontMono

    # Reason: 用 Tag 存储每行的结构化数据
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        [void]$listBox.Items.Add($i)
    }

    # Reason: 自定义绘制每一行，包含名称、部门、管理员、进度条、余量
    $listBox.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0) { return }
        $idx = $listBox.Items[$e.Index]
        $c = $Candidates[$idx]
        $isCurrent = ($CurrentKeyValue -and $c.Key -eq $CurrentKeyValue)
        $pct = if ($c.DailyLimit -gt 0) { [math]::Min($c.DailyUsed / $c.DailyLimit, 1.0) } else { 0 }

        # Background
        $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected)
        $rowBg = if ($isSelected) { [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55, 90, 127)) }
                 elseif ($idx % 2 -eq 1) { [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(38, 38, 38)) }
                 else { [System.Drawing.SolidBrush]::new($panelColor) }
        $e.Graphics.FillRectangle($rowBg, $e.Bounds)

        $y = $e.Bounds.Y
        $x = $e.Bounds.X + 10

        # Row 1: Name + Dept + Admin
        $nameStr = if ($isCurrent) { "$($c.Name)  (CURRENT)" } else { $c.Name }
        $nameColor = if ($isCurrent) { $accentBlue } else { $fgColor }
        $e.Graphics.DrawString($nameStr, $fontMono, [System.Drawing.SolidBrush]::new($nameColor), $x, $y + 3)
        $e.Graphics.DrawString("$($c.Dept) / $($c.Admin)", $fontBody, [System.Drawing.SolidBrush]::new($dimColor), $x + 200, $y + 4)

        # Row 2: Progress bar + remaining text
        $barX = $x
        $barY = $y + 21
        $barW = 200
        $barH = 10
        # Reason: 进度条底色
        $e.Graphics.FillRectangle([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(60, 60, 60)), $barX, $barY, $barW, $barH)
        # Reason: 已用部分，颜色按用量百分比渐变
        $barColor = if ($pct -lt 0.5) { $accentGreen } elseif ($pct -lt 0.8) { $accentYellow } else { $accentRed }
        $filledW = [int]($pct * $barW)
        if ($filledW -gt 0) { $e.Graphics.FillRectangle([System.Drawing.SolidBrush]::new($barColor), $barX, $barY, $filledW, $barH) }

        $leftStr = "  `$$($c.Remaining) / `$$($c.DailyLimit)  ($([math]::Round($pct * 100, 1))%)"
        $e.Graphics.DrawString($leftStr, $fontBody, [System.Drawing.SolidBrush]::new($dimColor), $barX + $barW + 2, $barY - 2)

        $rowBg.Dispose()
    })

    if ($listBox.Items.Count -gt 0) { $listBox.SelectedIndex = 0 }
    $form.Controls.Add($listBox)

    $result = @{ Choice = "cancel" }

    # -- Helper: create flat button --
    $makeBtn = {
        param([string]$text, [System.Drawing.Color]$bg, [int]$x, [int]$w)
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $text
        $btn.FlatStyle = "Flat"
        $btn.FlatAppearance.BorderSize = 0
        $btn.BackColor = $bg
        $btn.ForeColor = $fgColor
        $btn.Font = $fontBtn
        $btn.Location = New-Object System.Drawing.Point($x, 380)
        $btn.Size = New-Object System.Drawing.Size($w, 38)
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        return $btn
    }

    $btnAuto = & $makeBtn "  Auto Switch  " $accentGreen 20 170
    $btnAuto.ForeColor = [System.Drawing.Color]::White
    $btnAuto.Add_Click({ $result.Choice = "auto"; $form.Close() })
    $form.Controls.Add($btnAuto)

    $btnSelect = & $makeBtn "  Switch Selected  " $accentBlue 200 170
    $btnSelect.ForeColor = [System.Drawing.Color]::White
    $btnSelect.Add_Click({
        if ($listBox.SelectedIndex -ge 0) {
            # Reason: 终端列表序号从 1 开始，GUI 索引从 0 开始，+1 对齐
            $result.Choice = [string]($listBox.SelectedIndex + 1)
            $form.Close()
        }
    })
    $form.Controls.Add($btnSelect)

    $btnCancel = & $makeBtn "Cancel" $btnHover 440 105
    $btnCancel.Add_Click({ $result.Choice = "cancel"; $form.Close() })
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnAuto
    $form.CancelButton = $btnCancel
    [void]$form.ShowDialog()
    $form.Dispose()

    return $result.Choice
}
function FmtNum($n) {
    if ($null -eq $n) { return "N/A" }
    $v = [double]$n
    if ($v -ge 1000000000) { return ([math]::Round($v/1000000000, 2)).ToString() + "B" }
    if ($v -ge 1000000)    { return ([math]::Round($v/1000000, 2)).ToString() + "M" }
    if ($v -ge 1000)       { return ([math]::Round($v/1000, 1)).ToString() + "K" }
    return ([math]::Round($v, 2)).ToString()
}

# ---- Display Width Helpers (CJK chars = 2 cols) ----
function CharWidth([char]$c) {
    $code = [int]$c
    if (($code -ge 0x2E80 -and $code -le 0x9FFF) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFE30 -and $code -le 0xFE4F)) {
        return 2
    }
    return 1
}

function DisplayWidth([string]$s) {
    $w = 0
    foreach ($c in $s.ToCharArray()) { $w += (CharWidth $c) }
    return $w
}

function PadR([string]$s, [int]$targetWidth) {
    $dw = DisplayWidth $s
    if ($dw -gt $targetWidth) {
        $result = ""
        $w = 0
        foreach ($c in $s.ToCharArray()) {
            $cw = CharWidth $c
            if (($w + $cw) -gt ($targetWidth - 1)) { break }
            $result += $c
            $w += $cw
        }
        return $result + (" " * ($targetWidth - $w))
    }
    return $s + (" " * ($targetWidth - $dw))
}

function PadL([string]$s, [int]$targetWidth) {
    $dw = DisplayWidth $s
    $pad = $targetWidth - $dw
    if ($pad -lt 0) { $pad = 0 }
    return (" " * $pad) + $s
}

# ---- Progress Bar (ASCII) ----
function Bar {
    param([double]$Used, [double]$Total, [int]$Width = 40, [switch]$Invert)

    if ($Total -le 0) {
        WC "    [" DarkGray -NoNewline
        WC ("=" * $Width) DarkGray -NoNewline
        WC "] unlimited" DarkGray
        return
    }

    $pct    = [math]::Min($Used / $Total, 1.0)
    $filled = [int][math]::Round($pct * $Width)
    $empty  = $Width - $filled
    $pctStr = ([math]::Round($pct * 100, 1)).ToString() + "%"
    $left   = [math]::Round($Total - $Used, 4)

    if ($Invert) {
        $barColor = if ($pct -gt 0.5) { "Green" } elseif ($pct -gt 0.2) { "Yellow" } else { "Red" }
    }
    else {
        $barColor = if ($pct -lt 0.5) { "Green" } elseif ($pct -lt 0.8) { "Yellow" } else { "Red" }
    }

    WC "    [" DarkGray -NoNewline
    if ($filled -gt 0) { WC ("#" * $filled) $barColor -NoNewline }
    if ($empty  -gt 0) { WC ("." * $empty)  DarkGray  -NoNewline }
    WC "] " DarkGray -NoNewline
    WC $pctStr $barColor -NoNewline
    WC ("  used: `$" + ([math]::Round($Used,2)).ToString() + " / limit: `$" + ([math]::Round($Total,2)).ToString() + "  left: `$" + ([math]::Round($left,2)).ToString()) DarkGray
}

# ---- Mini Bar (compact, for dashboard/status) ----
function MiniBar {
    param([double]$Used, [double]$Total, [int]$Width = 20)
    if ($Total -le 0) { return "?" * $Width }
    $pct    = [math]::Min($Used / $Total, 1.0)
    $filled = [int][math]::Round($pct * $Width)
    $empty  = $Width - $filled
    $barColor = if ($pct -lt 0.5) { "Green" } elseif ($pct -lt 0.8) { "Yellow" } else { "Red" }
    WC "[" DarkGray -NoNewline
    if ($filled -gt 0) { WC ("#" * $filled) $barColor -NoNewline }
    if ($empty  -gt 0) { WC ("." * $empty)  DarkGray  -NoNewline }
    WC "]" DarkGray -NoNewline
}

# ----------------------------------------------------------------
# API Single Request
# ----------------------------------------------------------------
function ApiPost {
    param([string]$Path, [hashtable]$Body)
    try {
        $json = $Body | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod -Uri "$API_BASE$Path" -Method POST -Body $json -ContentType "application/json" -TimeoutSec 15 -ErrorAction Stop
        if ($r.success) {
            return [pscustomobject]@{ Ok = $true; Data = $r.data }
        } else {
            $errMsg = if ($r.message) { $r.message } elseif ($r.error) { [string]$r.error } else { "Unknown error" }
            return [pscustomobject]@{ Ok = $false; Error = $errMsg }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------
# API Batch Request (parallel via RunspacePool)
# ----------------------------------------------------------------
function BatchApiPost {
    param([array]$Requests, [int]$MaxThreads = 15)

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
    $pool.Open()

    $scriptBlock = {
        param([string]$Uri, [string]$JsonBody)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        try {
            $r = Invoke-RestMethod -Uri $Uri -Method POST -Body $JsonBody -ContentType "application/json" -TimeoutSec 15 -ErrorAction Stop
            if ($r.success) {
                [pscustomobject]@{ Ok = $true; Data = $r.data; Error = $null }
            } else {
                $errMsg = if ($r.message) { $r.message } elseif ($r.error) { [string]$r.error } else { "Unknown" }
                [pscustomobject]@{ Ok = $false; Data = $null; Error = $errMsg }
            }
        } catch {
            [pscustomobject]@{ Ok = $false; Data = $null; Error = $_.Exception.Message }
        }
    }

    $jobs = [System.Collections.ArrayList]::new()
    foreach ($req in $Requests) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $jsonBody = $req.Body | ConvertTo-Json -Depth 5
        [void]$ps.AddScript($scriptBlock).AddArgument($req.Uri).AddArgument($jsonBody)
        [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
    }

    $results = [System.Collections.ArrayList]::new()
    foreach ($j in $jobs) {
        $output = $j.PS.EndInvoke($j.Handle)
        if ($output -and $output.Count -gt 0) {
            [void]$results.Add($output[0])
        } else {
            [void]$results.Add([pscustomobject]@{ Ok = $false; Data = $null; Error = "No result" })
        }
        $j.PS.Dispose()
    }

    $pool.Close()
    $pool.Dispose()
    return $results
}

# ----------------------------------------------------------------
# Get current API key from environment
# ----------------------------------------------------------------
function GetCurrentKey {
    # Reason: Claude Code uses ANTHROPIC_AUTH_TOKEN, check process-level first (running session)
    $key = $env:ANTHROPIC_AUTH_TOKEN
    if ($key) { return $key }
    $key = $env:ANTHROPIC_API_KEY
    if ($key) { return $key }
    # Fallback to User-level (persisted for new sessions)
    $key = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User")
    if ($key) { return $key }
    $key = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
    if ($key) { return $key }
    return $null
}

# ----------------------------------------------------------------
# Query all keys and return sorted results
# ----------------------------------------------------------------
function QueryAllKeys {
    WC "  Querying $($API_KEYS.Count) keys in parallel..." DarkGray

    # Phase 1: Resolve key IDs
    $idRequests = @()
    foreach ($entry in $API_KEYS) {
        $idRequests += @{ Uri = "$API_BASE/apiStats/api/get-key-id"; Body = @{ apiKey = $entry.Key } }
    }
    $idResults = BatchApiPost -Requests $idRequests

    # Phase 2: Get stats for resolved keys
    $statsRequests = @()
    $resolvedMap = @{}
    for ($i = 0; $i -lt $API_KEYS.Count; $i++) {
        if ($idResults[$i].Ok) {
            $statsRequests += @{ Uri = "$API_BASE/apiStats/api/user-stats"; Body = @{ apiId = $idResults[$i].Data.id } }
            $resolvedMap[$statsRequests.Count - 1] = $i
        }
    }

    $statsResults = @()
    if ($statsRequests.Count -gt 0) {
        $statsResults = BatchApiPost -Requests $statsRequests
    }

    # Build result list
    $keyInfos = [System.Collections.ArrayList]::new()
    for ($j = 0; $j -lt $statsRequests.Count; $j++) {
        $origIdx = $resolvedMap[$j]
        $entry = $API_KEYS[$origIdx]

        if (-not $statsResults[$j].Ok) {
            [void]$keyInfos.Add([pscustomobject]@{
                Name      = $entry.Name
                Key       = $entry.Key
                Dept      = $entry.Dept
                Admin     = $entry.Admin
                DailyUsed = 0
                DailyLimit = 0
                Remaining = 0
                Active    = $false
                Error     = $statsResults[$j].Error
            })
            continue
        }

        $d = $statsResults[$j].Data
        $dailyUsed  = [double]$d.limits.currentDailyCost
        $dailyLimit = [double]$d.limits.dailyCostLimit
        $remaining  = [math]::Round($dailyLimit - $dailyUsed, 2)

        [void]$keyInfos.Add([pscustomobject]@{
            Name       = $entry.Name
            Key        = $entry.Key
            Dept       = $entry.Dept
            Admin      = $entry.Admin
            DailyUsed  = [math]::Round($dailyUsed, 2)
            DailyLimit = [math]::Round($dailyLimit, 0)
            Remaining  = $remaining
            Active     = [bool]$d.isActive
            Error      = $null
        })
    }

    # Add failed keys (those that couldn't resolve)
    for ($i = 0; $i -lt $API_KEYS.Count; $i++) {
        if (-not $idResults[$i].Ok) {
            $entry = $API_KEYS[$i]
            [void]$keyInfos.Add([pscustomobject]@{
                Name       = $entry.Name
                Key        = $entry.Key
                Dept       = $entry.Dept
                Admin      = $entry.Admin
                DailyUsed  = 0
                DailyLimit = 0
                Remaining  = 0
                Active     = $false
                Error      = "Resolve failed: $($idResults[$i].Error)"
            })
        }
    }

    return $keyInfos
}

# ----------------------------------------------------------------
# Switch API key
# ----------------------------------------------------------------
function SwitchKey {
    param([string]$NewKey, [string]$KeyName)

    # Reason: Claude Code reads ANTHROPIC_AUTH_TOKEN, not ANTHROPIC_API_KEY
    # Set User-level env var (persistent, effective for new processes)
    [System.Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", $NewKey, "User")

    # Ensure BASE_URL is also persisted for new Claude Code sessions
    $baseUrl = $env:ANTHROPIC_BASE_URL
    if ($baseUrl) {
        [System.Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $baseUrl, "User")
    }

    # Set process-level for current PowerShell session
    $env:ANTHROPIC_AUTH_TOKEN = $NewKey

    WC "  [SWITCHED] API key -> $KeyName" Green
    WC "  Key: $($NewKey.Substring(0,10))...$($NewKey.Substring($NewKey.Length-4))" DarkGray
    Log "SWITCHED to $KeyName ($($NewKey.Substring(0,10))...$($NewKey.Substring($NewKey.Length-4)))"

    Write-Host ""
    WC "  [提醒] 需要重启 Claude Code 才能使用新 Key:" Yellow
    WC "    VS Code: 关闭并重新打开窗口，在 Claude Code 面板输入 /resume" DarkGray
    WC "    CLI:     打开新终端，cd 到项目目录，运行 claude --resume" DarkGray

    # Reason: Monitor 模式下弹出系统通知，用户不在终端也能看到
    if ($Monitor) {
        Notify -Title "API Key 已切换" -Body "已切换到 $KeyName，请重启 Claude Code 使新 Key 生效" -Level "Warning"
    }
}

# ----------------------------------------------------------------
# Display help
# ----------------------------------------------------------------
function ShowHelp {
    Write-Host ""
    WC "  Claude Code API Key Auto-Switcher - 帮助文档" Cyan
    WC "  =============================================" Cyan
    Write-Host ""
    WC "  功能说明:" Yellow
    WC "    当 Claude Code 的 API Key 每日额度用完时，自动从 api-keys.json 中" DarkGray
    WC "    查询所有可用 key，找到剩余每日额度最多的 key，并切换环境变量。" DarkGray
    WC "    支持后台持续监控，额度不足时自动弹窗提醒并切换。" DarkGray
    Write-Host ""
    WC "  用法:" Yellow
    WC "    .\auto-switch-key.ps1                         一次性检测并切换（默认模式）" White
    WC "    .\auto-switch-key.ps1 -Current                查看当前使用的 key 详细信息" White
    WC "    .\auto-switch-key.ps1 -Name osr-p4_3          查询指定 key 的详细信息" White
    WC "    .\auto-switch-key.ps1 -Name -ALL              所有 key 详细信息（含模型消费明细）" White
    WC "    .\auto-switch-key.ps1 -Status                 所有 key 按剩余额度排名" White
    WC "    .\auto-switch-key.ps1 -Dashboard              所有 key 每日消费概览（配置顺序）" White
    WC "    .\auto-switch-key.ps1 -Threshold 10           余量低于 `$10 时自动切换" White
    WC "    .\auto-switch-key.ps1 -Monitor                持续监控模式（默认每 5 分钟检测）" White
    WC "    .\auto-switch-key.ps1 -Monitor -Interval 120  自定义监控间隔（120 秒）" White
    WC "    .\auto-switch-key.ps1 -Background             后台监控（隐藏窗口，关终端也不影响）" White
    WC "    .\auto-switch-key.ps1 -Stop                   停止后台监控" White
    WC "    .\auto-switch-key.ps1 -DryRun                 模拟运行，不实际切换（测试用）" White
    WC "    .\auto-switch-key.ps1 -Help                   显示本帮助信息" White
    Write-Host ""
    WC "  查询参数:" Yellow
    WC "    -Current        查看当前正在使用的 API Key 详细信息" DarkGray
    WC "                    包含：状态、每日/总消费、Token 统计、模型消费明细" DarkGray
    WC "    -Name <string>  查询指定 key 的详细信息（含每模型消费明细）" DarkGray
    WC "                    名称必须完全匹配，如: -Name osr-p4_3" DarkGray
    WC "    -Name -ALL      显示所有 key 的完整详细信息（并行查询）" DarkGray
    WC "                    包含：状态、每日/总消费、Token 统计、各模型消费明细" DarkGray
    WC "                    等价于对每个 key 执行 -Name 查询" DarkGray
    WC "    -Status         显示所有 key 按剩余额度从高到低的排名表" DarkGray
    WC "                    标注当前使用的 key，显示最佳可用 key" DarkGray
    WC "    -Dashboard      面板模式：所有 key 按配置顺序的每日消费概览" DarkGray
    WC "                    与 -Status 区别：不排序、纯信息概览" DarkGray
    Write-Host ""
    WC "  切换参数:" Yellow
    WC "    -Threshold N    剩余每日额度低于 `$N 时触发自动切换，默认 `$5" DarkGray
    WC "                    可单独使用（一次性检测）或配合 -Monitor（持续监控）" DarkGray
    WC "    -Monitor        启用持续监控模式，脚本不会退出，按 Ctrl+C 停止" DarkGray
    WC "    -Interval N     监控间隔（秒），必须配合 -Monitor 使用，默认 300" DarkGray
    WC "    -Background     在后台启动 Monitor（隐藏窗口），关掉终端也不影响" DarkGray
    WC "                    额度不足时弹出 GUI 窗口选择切换目标" DarkGray
    WC "                    PID 保存在 monitor.pid，用 -Stop 停止" DarkGray
    WC "    -Stop           停止后台运行的 Monitor（读取 monitor.pid 并终止进程）" DarkGray
    WC "    -DryRun         模拟运行（Dry Run = 演习），不实际切换、不改环境变量" DarkGray
    WC "                    走完整个检测流程，只显示「会切换到哪个 key」" DarkGray
    WC "                    常用组合: -DryRun -Threshold 999（查看当前最优 key）" DarkGray
    WC "    -Help           显示本帮助信息" DarkGray
    Write-Host ""
    WC "  参数使用说明:" Yellow
    WC "    可单独使用: -Current  -Name  -Name -ALL  -Status  -Dashboard  -Stop  -Help" DarkGray
    WC "               -Monitor  -Background  -Threshold  -DryRun" DarkGray
    WC "    需组合使用: -Interval（必须配合 -Monitor）" DarkGray
    Write-Host ""
    WC "  工作原理:" Yellow
    WC "    1. 读取 api-keys.json 中所有 key 配置" DarkGray
    WC "    2. 并行查询 OSR API 获取每个 key 的当日已用额度和限额" DarkGray
    WC "    3. 获取当前环境变量 ANTHROPIC_AUTH_TOKEN 对应的 key" DarkGray
    WC "    4. 如果当前 key 剩余额度 <= 阈值，显示所有 key 状态供选择" DarkGray
    WC "    5. 可选自动切换（余量最多）或手动指定序号" DarkGray
    WC "    6. 切换时设置 User 级别的 ANTHROPIC_AUTH_TOKEN 和 ANTHROPIC_BASE_URL" DarkGray
    WC "    7. 提示用户重启 Claude Code 使新 Key 生效" DarkGray
    Write-Host ""
    WC "  切换后恢复说明:" Yellow
    WC "    切换 key 后需要重启 Claude Code 才能使用新 Key:" DarkGray
    WC "    VS Code: 关闭并重新打开窗口，在 Claude Code 面板输入 /resume" DarkGray
    WC "    CLI:     打开新终端，cd 到项目目录，运行 claude --resume" DarkGray
    Write-Host ""
    WC "  使用示例:" Yellow
    WC "    .\auto-switch-key.ps1 -Current" Green
    WC "      => 查看当前 key 的名称、额度、模型消费明细" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Name osr-p4_4" Green
    WC "      => 查看 osr-p4_4 的完整使用详情" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Name -ALL" Green
    WC "      => 一次性查看所有 key 的详细信息，含模型消费明细" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Status" Green
    WC "      => 快速查看所有 key 今日剩余额度排名" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Dashboard" Green
    WC "      => 所有 key 每日消费概览（按配置顺序）" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Threshold 20" Green
    WC "      => 一次性检测，余量低于 `$20 时自动切换到最优 key" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Monitor -Interval 60" Green
    WC "      => 每 60 秒检测一次，额度不足时自动切换" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Monitor -Threshold 10" Green
    WC "      => 持续监控，额度低于 `$10 时自动切换" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -DryRun -Threshold 999" Green
    WC "      => 模拟运行：强制触发切换逻辑，查看会切换到哪个 key（不实际切换）" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Background" Green
    WC "      => 后台启动监控，关掉终端也持续运行，额度不足时弹窗提醒" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Background -Interval 60 -Threshold 10" Green
    WC "      => 后台监控，60 秒间隔，余量低于 `$10 时触发切换" DarkGray
    Write-Host ""
    WC "    .\auto-switch-key.ps1 -Stop" Green
    WC "      => 停止后台监控进程" DarkGray
    Write-Host ""
    WC "  注意事项:" Yellow
    WC "    - 所有 key 每日限额 `$100（含 p4 和 v2 系列）" DarkGray
    WC "    - 每日限额在 UTC 0:00 重置" DarkGray
    WC "    - 日志文件: switch-key.log（与脚本同目录）" DarkGray
    WC "    - -Interval 不能单独使用，必须配合 -Monitor" DarkGray
    WC "    - -Threshold 可单独使用，也可配合 -Monitor 持续监控" DarkGray
    WC "    - -Background 启动后可关闭终端，监控在后台持续运行" DarkGray
    WC "    - PID 文件: monitor.pid（与脚本同目录），-Stop 读取此文件停止进程" DarkGray
    Write-Host ""
    WC "  当前已配置密钥 ($($API_KEYS.Count) 个):" Yellow
    foreach ($k in $API_KEYS) {
        $short = $k.Key.Substring(0, 10) + "..." + $k.Key.Substring($k.Key.Length - 4)
        WC "    $(PadR $k.Name 14) $(PadR $k.Dept 10) $(PadR $k.Admin 14) $short" DarkGray
    }
    Write-Host ""
}

# ----------------------------------------------------------------
# Query one key (detailed view with model breakdown)
# Reason: 通用单 key 详情函数，供 -Current 和 -Name 复用
# ----------------------------------------------------------------
function QueryKey {
    param(
        [string]$KeyName, [string]$Key, [string]$Dept = "", [string]$Admin = "",
        $PreStats = $null, $PreModel = $null
    )

    $short = $Key.Substring(0, [math]::Min(10, $Key.Length)) + "..." + $Key.Substring([math]::Max(0, $Key.Length - 4))
    $sep = "-" * 66

    Write-Host ""
    WC "  +$sep+" Cyan
    WC "  | $KeyName  ($short)" Cyan
    if ($Dept -or $Admin) {
        WC "  | Dept: $Dept   Admin: $Admin" Cyan
    }
    WC "  +$sep+" Cyan

    if ($PreStats) {
        # Reason: parallel 模式下使用预取数据，避免重复查询
        $d = $PreStats
        $modelResp = $PreModel
    } else {
        # Serial fetch (single key mode)
        WC "    Resolving key..." DarkGray -NoNewline
        $idResp = ApiPost -Path "/apiStats/api/get-key-id" -Body @{ apiKey = $Key }
        Write-Host "`r                         `r" -NoNewline

        if (-not $idResp.Ok) {
            WC "    [FAIL] Cannot resolve key: $($idResp.Error)" Red
            return
        }
        $apiId = $idResp.Data.id

        WC "    Fetching stats..." DarkGray -NoNewline
        $statsResp = ApiPost -Path "/apiStats/api/user-stats" -Body @{ apiId = $apiId }
        Write-Host "`r                         `r" -NoNewline

        if (-not $statsResp.Ok) {
            WC "    [FAIL] Cannot get stats: $($statsResp.Error)" Red
            return
        }
        $d = $statsResp.Data

        $modelResp = ApiPost -Path "/apiStats/api/user-model-stats" -Body @{ apiId = $apiId; period = "daily" }
    }

    # -- Status --
    Write-Host ""
    WC "  -- Status --" Yellow
    WC "    Name     : " DarkGray -NoNewline; WC $d.name White
    if ($Dept)  { WC "    Dept     : " DarkGray -NoNewline; WC $Dept Cyan }
    if ($Admin) { WC "    Admin    : " DarkGray -NoNewline; WC $Admin Cyan }
    WC "    Active   : " DarkGray -NoNewline
    if ($d.isActive) { WC "[ACTIVE]" Green } else { WC "[INACTIVE]" Red }
    WC "    Created  : $($d.createdAt)" DarkGray
    if ($d.expiresAt) { WC "    Expires  : $($d.expiresAt)" DarkGray }
    WC "    Concurrency: $($d.limits.concurrencyLimit)" DarkGray

    # -- Daily Cost --
    Write-Host ""
    WC "  -- Daily Cost Limit --" Yellow
    $dailyUsed  = [double]$d.limits.currentDailyCost
    $dailyLimit = [double]$d.limits.dailyCostLimit
    WC "    Today spent: " DarkGray -NoNewline
    WC ("`$" + ([math]::Round($dailyUsed, 4)).ToString()) White -NoNewline
    if ($dailyLimit -gt 0) {
        WC (" / limit: `$" + $dailyLimit.ToString()) DarkGray
        Bar -Used $dailyUsed -Total $dailyLimit -Width 42
    } else {
        WC " (no daily limit)" DarkGray
    }

    # -- Total Cost --
    Write-Host ""
    WC "  -- Total Cost --" Yellow
    $totalUsed  = [double]$d.limits.currentTotalCost
    $totalLimit = [double]$d.limits.totalCostLimit
    WC "    Total spent: " DarkGray -NoNewline
    WC ("`$" + ([math]::Round($totalUsed, 2)).ToString()) White -NoNewline
    WC (" ($($d.usage.total.formattedCost))") DarkGray
    if ($totalLimit -gt 0) {
        Bar -Used $totalUsed -Total $totalLimit -Width 42
    } else {
        WC "    (no total cost limit)" DarkGray
    }

    # -- Weekly Opus Cost --
    $wOpus  = [double]$d.limits.weeklyOpusCost
    $wLimit = [double]$d.limits.weeklyOpusCostLimit
    if ($wLimit -gt 0) {
        Write-Host ""
        WC "  -- Weekly Opus Cost --" Yellow
        WC "    Opus this week: " DarkGray -NoNewline
        WC ("`$" + ([math]::Round($wOpus, 2)).ToString()) White -NoNewline
        WC (" / limit: `$" + $wLimit.ToString()) DarkGray
        Bar -Used $wOpus -Total $wLimit -Width 42
    }

    # -- Token Usage (all-time) --
    Write-Host ""
    WC "  -- Token Usage (all-time) --" Yellow
    $u = $d.usage.total
    WC "    Requests     : $(FmtNum $u.requests)" DarkGray
    WC "    Input tokens : $(FmtNum $u.inputTokens)" DarkGray
    WC "    Output tokens: $(FmtNum $u.outputTokens)" DarkGray
    WC "    Cache write  : $(FmtNum $u.cacheCreateTokens)" DarkGray
    WC "    Cache read   : $(FmtNum $u.cacheReadTokens)" DarkGray
    WC "    Total tokens : " DarkGray -NoNewline; WC (FmtNum $u.allTokens) White

    # -- Today's Model Breakdown --
    if ($modelResp.Ok -and $modelResp.Data -and $modelResp.Data.Count -gt 0) {
        Write-Host ""
        WC "  -- Today's Model Breakdown --" Yellow

        $hdr = "    {0,-32} {1,6} {2,10} {3,10} {4,10}" -f "MODEL", "REQ", "INPUT", "OUTPUT", "COST"
        WC $hdr DarkGray
        WC ("    " + ("-" * 72)) DarkGray

        $todayTotal = 0
        foreach ($m in $modelResp.Data) {
            $cost = [double]$m.costs.total
            $todayTotal += $cost
            $line = "    {0,-32} {1,6} {2,10} {3,10} {4,10}" -f $m.model, $m.requests, (FmtNum $m.inputTokens), (FmtNum $m.outputTokens), $m.formatted.total
            WC $line White
        }

        WC ("    " + ("-" * 72)) DarkGray
        $todaySummary = "    {0,-32} {1,6} {2,10} {3,10} {4,10}" -f "TOTAL", "", "", "", ("`$" + ([math]::Round($todayTotal, 4)).ToString())
        WC $todaySummary Yellow

        if ($dailyLimit -gt 0) {
            Write-Host ""
            WC "    Today cost vs daily limit:" DarkGray
            Bar -Used $todayTotal -Total $dailyLimit -Width 42
            $remaining = [math]::Round($dailyLimit - $todayTotal, 2)
            WC "    >>> " DarkGray -NoNewline
            if ($remaining -gt 0) {
                WC "Remaining today: `$$remaining" Green
            } else {
                WC "Daily limit reached!" Red
            }
        }
    }

    Write-Host ""
}

# ----------------------------------------------------------------
# Show current key info (thin wrapper around QueryKey)
# ----------------------------------------------------------------
function ShowCurrentKey {
    $currentKey = GetCurrentKey
    if (-not $currentKey) {
        Write-Host ""
        WC "  [WARN] 未找到当前 API Key（环境变量 ANTHROPIC_AUTH_TOKEN 未设置）" Yellow
        Write-Host ""
        return
    }

    $entry = $API_KEYS | Where-Object { $_.Key -eq $currentKey } | Select-Object -First 1
    if (-not $entry) {
        $short = $currentKey.Substring(0, 10) + "..." + $currentKey.Substring($currentKey.Length - 4)
        Write-Host ""
        WC "  [WARN] 当前 key ($short) 不在 api-keys.json 配置中" Yellow
        Write-Host ""
        return
    }

    # Reason: 复用 QueryKey 避免代码重复
    QueryKey -KeyName $entry.Name -Key $entry.Key -Dept $entry.Dept -Admin $entry.Admin
}

# ----------------------------------------------------------------
# Show status (all keys ranked by remaining budget) - Dashboard style
# ----------------------------------------------------------------
function ShowStatus {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalW = 88

    Write-Host ""
    WC ("+$("=" * $totalW)+") Blue
    WC "|  API Key Budget Ranking   [$($API_KEYS.Count) keys]   $ts" Blue
    WC ("+$("=" * $totalW)+") Blue
    Write-Host ""

    $currentKey = GetCurrentKey
    $keyInfos = QueryAllKeys

    # Sort by remaining budget descending
    $sorted = $keyInfos | Where-Object { $null -eq $_.Error -and $_.Active } | Sort-Object -Property Remaining -Descending

    # Column widths: KEY=14  DEPT=10  ADMIN=14  USED=9  LIMIT=6  LEFT=9  BAR=22  PCT=6
    $hdr = "  $(PadR 'KEY' 14) $(PadR 'DEPT' 10) $(PadR 'ADMIN' 14) $(PadL 'USED' 9) $(PadL 'LIMIT' 6) $(PadL 'LEFT' 9)  PROGRESS"
    WC $hdr Yellow
    WC ("  " + ("-" * $totalW)) DarkGray

    $grandUsed  = 0.0
    $grandLimit = 0.0

    foreach ($k in $sorted) {
        $usedStr  = "`$" + $k.DailyUsed.ToString()
        $limitStr = "`$" + $k.DailyLimit.ToString()
        $leftStr  = "`$" + $k.Remaining.ToString()

        $grandUsed  += $k.DailyUsed
        $grandLimit += $k.DailyLimit

        $isCurrent = ($currentKey -and $k.Key -eq $currentKey)
        $pct = if ($k.DailyLimit -gt 0) { [math]::Min($k.DailyUsed / $k.DailyLimit, 1.0) } else { 0 }
        $rowColor = if ($pct -lt 0.5) { "White" } elseif ($pct -lt 0.8) { "Yellow" } else { "Red" }
        if ($isCurrent) { $rowColor = "Cyan" }
        $pctStr = ([math]::Round($pct * 100, 1)).ToString() + "%"

        $prefix = "  $(PadR $k.Name 14) $(PadR $k.Dept 10) $(PadR $k.Admin 14) $(PadL $usedStr 9) $(PadL $limitStr 6) $(PadL $leftStr 9)  "
        WC $prefix $rowColor -NoNewline
        MiniBar -Used $k.DailyUsed -Total $k.DailyLimit -Width 20
        $mark = if ($isCurrent) { " <-- CURRENT" } else { "" }
        WC " $(PadL $pctStr 6)$mark" $rowColor
    }

    # Summary
    WC ("  " + ("-" * $totalW)) DarkGray
    $grandLeft = [math]::Round($grandLimit - $grandUsed, 2)
    $summary = "  $(PadR 'TOTAL' 14) $(PadR '' 10) $(PadR '' 14) $(PadL ("`$" + ([math]::Round($grandUsed, 2)).ToString()) 9) $(PadL ("`$" + ([math]::Round($grandLimit, 0)).ToString()) 6) $(PadL ("`$" + $grandLeft.ToString()) 9)"
    WC $summary Cyan

    # Show errors
    $errors = $keyInfos | Where-Object { $null -ne $_.Error }
    if ($errors.Count -gt 0) {
        Write-Host ""
        WC "  [ERRORS] $($errors.Count) key(s) failed to query:" Red
        foreach ($e in $errors) {
            WC "    $($e.Name): $($e.Error)" DarkGray
        }
    }

    Write-Host ""
    if ($sorted.Count -gt 0) {
        WC "  Best available: $($sorted[0].Name) (remaining: `$$($sorted[0].Remaining))" Green
    }
    Write-Host ""
}

# ----------------------------------------------------------------
# Dashboard: compact daily cost overview (config order)
# Reason: 与 -Status 区别：按配置顺序显示，纯信息概览
# ----------------------------------------------------------------
function ShowDashboard {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalW = 88

    Write-Host ""
    WC ("+$("=" * $totalW)+") Blue
    WC "|  OSR Daily Cost Dashboard   [$($API_KEYS.Count) keys]   $ts" Blue
    WC ("+$("=" * $totalW)+") Blue
    Write-Host ""

    # Column widths: KEY=14  DEPT=10  ADMIN=14  USED=9  LIMIT=6  LEFT=9  BAR=22  PCT=6
    $hdr = "  $(PadR 'KEY' 14) $(PadR 'DEPT' 10) $(PadR 'ADMIN' 14) $(PadL 'USED' 9) $(PadL 'LIMIT' 6) $(PadL 'LEFT' 9)  PROGRESS"
    WC $hdr Yellow
    WC ("  " + ("-" * $totalW)) DarkGray

    # Reason: 并行获取所有 key 数据，然后按配置顺序渲染
    WC "  Fetching all keys in parallel..." DarkGray -NoNewline
    $idRequests = @()
    foreach ($entry in $API_KEYS) {
        $idRequests += @{ Uri = "$API_BASE/apiStats/api/get-key-id"; Body = @{ apiKey = $entry.Key } }
    }
    $idResults = BatchApiPost -Requests $idRequests

    $statsRequests = @()
    $resolvedIndices = @()
    for ($i = 0; $i -lt $API_KEYS.Count; $i++) {
        if ($idResults[$i].Ok) {
            $statsRequests += @{ Uri = "$API_BASE/apiStats/api/user-stats"; Body = @{ apiId = $idResults[$i].Data.id } }
            $resolvedIndices += $i
        }
    }
    $statsResults = @()
    if ($statsRequests.Count -gt 0) {
        $statsResults = BatchApiPost -Requests $statsRequests
    }

    Write-Host "`r                                          `r" -NoNewline

    $statsLookup = @{}
    for ($j = 0; $j -lt $resolvedIndices.Count; $j++) {
        $statsLookup[$resolvedIndices[$j]] = $statsResults[$j]
    }

    $grandUsed  = 0.0
    $grandLimit = 0.0

    for ($i = 0; $i -lt $API_KEYS.Count; $i++) {
        $entry = $API_KEYS[$i]

        if (-not $idResults[$i].Ok -or -not $statsLookup.ContainsKey($i) -or -not $statsLookup[$i].Ok) {
            $line = "  $(PadR $entry.Name 14) $(PadR $entry.Dept 10) $(PadR $entry.Admin 14) $(PadL 'ERR' 9) $(PadL '-' 6) $(PadL '-' 9)"
            WC $line Red
            continue
        }

        $d = $statsLookup[$i].Data
        $used  = [double]$d.limits.currentDailyCost
        $limit = [double]$d.limits.dailyCostLimit
        $left  = [math]::Round($limit - $used, 2)

        $grandUsed  += $used
        $grandLimit += $limit

        $usedStr  = "`$" + ([math]::Round($used, 2)).ToString()
        $limitStr = "`$" + ([math]::Round($limit, 0)).ToString()
        $leftStr  = "`$" + ([math]::Round($left, 2)).ToString()

        $pct = if ($limit -gt 0) { [math]::Min($used / $limit, 1.0) } else { 0 }
        $rowColor = if ($pct -lt 0.5) { "White" } elseif ($pct -lt 0.8) { "Yellow" } else { "Red" }
        $pctStr = ([math]::Round($pct * 100, 1)).ToString() + "%"

        $prefix = "  $(PadR $entry.Name 14) $(PadR $entry.Dept 10) $(PadR $entry.Admin 14) $(PadL $usedStr 9) $(PadL $limitStr 6) $(PadL $leftStr 9)  "
        WC $prefix $rowColor -NoNewline
        MiniBar -Used $used -Total $limit -Width 20
        WC " $(PadL $pctStr 6)" $rowColor
    }

    # Summary
    WC ("  " + ("-" * $totalW)) DarkGray
    $grandLeft = [math]::Round($grandLimit - $grandUsed, 2)
    $summary = "  $(PadR 'TOTAL' 14) $(PadR '' 10) $(PadR '' 14) $(PadL ("`$" + ([math]::Round($grandUsed, 2)).ToString()) 9) $(PadL ("`$" + ([math]::Round($grandLimit, 0)).ToString()) 6) $(PadL ("`$" + $grandLeft.ToString()) 9)"
    WC $summary Cyan
    Write-Host ""
}

# ----------------------------------------------------------------
# Core: Check and switch
# ----------------------------------------------------------------
function CheckAndSwitch {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host ""
    WC "  [$ts] Checking API key status..." Cyan

    $currentKey = GetCurrentKey
    if (-not $currentKey) {
        WC "  [WARN] No current API key found in environment." Yellow
        WC "  Will select the best key and set it." Yellow
    }

    $keyInfos = QueryAllKeys

    # Find current key info
    $currentInfo = $null
    if ($currentKey) {
        $currentInfo = $keyInfos | Where-Object { $_.Key -eq $currentKey } | Select-Object -First 1
    }

    # Show current key status
    if ($currentInfo) {
        $short = $currentKey.Substring(0, 10) + "..." + $currentKey.Substring($currentKey.Length - 4)
        WC "  Current key: $($currentInfo.Name) ($short)" White
        WC "  Daily used: `$$($currentInfo.DailyUsed) / limit: `$$($currentInfo.DailyLimit) / remaining: `$$($currentInfo.Remaining)" DarkGray
        if ($currentInfo.DailyLimit -gt 0) {
            Bar -Used $currentInfo.DailyUsed -Total $currentInfo.DailyLimit -Width 42
        }
    } elseif ($currentKey) {
        $short = $currentKey.Substring(0, 10) + "..." + $currentKey.Substring($currentKey.Length - 4)
        WC "  Current key: $short (not found in config)" Yellow
    }

    # Get best available key (active, no error, most remaining)
    $candidates = $keyInfos | Where-Object { $null -eq $_.Error -and $_.Active -and $_.Remaining -gt 0 } | Sort-Object -Property Remaining -Descending
    if ($candidates.Count -eq 0) {
        WC "  [ERROR] No available keys with remaining budget!" Red
        Log "ERROR: No available keys with remaining budget"
        if ($Monitor) { Notify -Title "API Key 额度耗尽" -Body "所有 Key 余量为零，无法切换！" -Level "Error" }
        return $false
    }

    $bestKey = $candidates[0]
    WC "  Best key: $($bestKey.Name) (remaining: `$$($bestKey.Remaining))" Green

    # Decide whether to switch
    $needSwitch = $false
    if (-not $currentKey) {
        $needSwitch = $true
        WC "  [ACTION] No current key set, will switch to best key." Yellow
    } elseif (-not $currentInfo) {
        $needSwitch = $true
        WC "  [ACTION] Current key not in config, will switch to best key." Yellow
    } elseif ($currentInfo.Remaining -le $Threshold) {
        $needSwitch = $true
        WC "  [ACTION] Current key remaining (`$$($currentInfo.Remaining)) <= threshold (`$$Threshold), switching..." Yellow
    } elseif (-not $currentInfo.Active) {
        $needSwitch = $true
        WC "  [ACTION] Current key is INACTIVE, switching..." Yellow
    } else {
        WC "  [OK] Current key still has `$$($currentInfo.Remaining) remaining (threshold: `$$Threshold). No switch needed." Green
    }

    if ($needSwitch) {
        # Reason: 切换前打印所有 key 状态，格式对齐 -Status 表格
        Write-Host ""
        WC "  -- 可用 Key 列表 --" Yellow
        # Column widths: NO=4  KEY=14  DEPT=10  ADMIN=14  USED=9  LIMIT=6  LEFT=9  BAR=22  PCT=6
        $hdr = "  $(PadR '#' 4) $(PadR 'KEY' 14) $(PadR 'DEPT' 10) $(PadR 'ADMIN' 14) $(PadL 'USED' 9) $(PadL 'LIMIT' 6) $(PadL 'LEFT' 9)  PROGRESS"
        WC $hdr Yellow
        WC ("  " + ("-" * 96)) DarkGray

        $idx = 1
        foreach ($c in $candidates) {
            $isCurrent = ($currentKey -and $c.Key -eq $currentKey)
            $usedStr  = "`$" + $c.DailyUsed.ToString()
            $limitStr = "`$" + $c.DailyLimit.ToString()
            $leftStr  = "`$" + $c.Remaining.ToString()
            $pct = if ($c.DailyLimit -gt 0) { [math]::Min($c.DailyUsed / $c.DailyLimit, 1.0) } else { 0 }
            $pctStr = ([math]::Round($pct * 100, 1)).ToString() + "%"
            $color = if ($pct -lt 0.5) { "White" } elseif ($pct -lt 0.8) { "Yellow" } else { "Red" }
            if ($isCurrent) { $color = "Cyan" }
            $mark = if ($isCurrent) { " <-- CURRENT" } else { "" }

            $prefix = "  $(PadR "[$idx]" 4) $(PadR $c.Name 14) $(PadR $c.Dept 10) $(PadR $c.Admin 14) $(PadL $usedStr 9) $(PadL $limitStr 6) $(PadL $leftStr 9)  "
            WC $prefix $color -NoNewline
            MiniBar -Used $c.DailyUsed -Total $c.DailyLimit -Width 20
            WC " $(PadL $pctStr 6)$mark" $color
            $idx++
        }
        WC ("  " + ("-" * 96)) DarkGray

        Write-Host ""
        WC "  切换方式: A=自动切换余量最多的 key, 输入序号=指定 key" Cyan

        # Reason: Monitor 模式弹 GUI 窗口选择，非 Monitor 用终端 Read-Host
        if ($Monitor) {
            Notify -Title "API Key 额度不足" -Body "当前 Key 余量不足，请在弹窗中选择切换目标" -Level "Warning"
            $choice = ShowKeySelectorDialog -Candidates $candidates -CurrentKeyValue $currentKey
        } else {
            $choice = Read-Host "  请选择 (回车=A)"
            if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "auto" }
        }

        $targetKey = $null
        if ($choice -match '^[Aa]' -or $choice -eq "auto") {
            # Reason: 自动模式选余量最多且非当前的 key
            $targetKey = $candidates[0]
            if ($currentKey -and $targetKey.Key -eq $currentKey) {
                if ($candidates.Count -gt 1) {
                    $targetKey = $candidates[1]
                    WC "  余量最多的就是当前 key，已选第二: $($targetKey.Name)" Yellow
                } else {
                    WC "  [WARN] 没有更好的 key 可切换" Yellow
                    return $false
                }
            }
        } elseif ($choice -match '^\d+$') {
            $num = [int]$choice
            if ($num -ge 1 -and $num -le $candidates.Count) {
                $targetKey = $candidates[$num - 1]
                if ($currentKey -and $targetKey.Key -eq $currentKey) {
                    WC "  [WARN] 选择的就是当前 key，无需切换" Yellow
                    return $false
                }
            } else {
                WC "  [ERROR] 无效序号: $choice" Red
                return $false
            }
        } else {
            WC "  [SKIP] 已取消切换" DarkGray
            return $false
        }

        if ($DryRun) {
            WC "  [DRY RUN] Would switch to: $($targetKey.Name) (remaining: `$$($targetKey.Remaining))" Magenta
            Log "DRY RUN: Would switch to $($targetKey.Name)"
        } else {
            SwitchKey -NewKey $targetKey.Key -KeyName $targetKey.Name
        }
        return $true
    }

    return $false
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

if ($Help) {
    ShowHelp
    exit 0
}

# ---- Stop background monitor ----
if ($Stop) {
    if (-not (Test-Path $pidFile)) {
        WC "  [INFO] 没有运行中的后台 Monitor（$pidFile 不存在）" Yellow
        exit 0
    }
    $savedPid = (Get-Content $pidFile -Raw).Trim()
    $bgProc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
    if ($bgProc) {
        Stop-Process -Id $savedPid -Force
        WC "  [Background] 已停止后台 Monitor (PID: $savedPid)" Green
        Log "Background monitor stopped (PID: $savedPid)"
    } else {
        WC "  [INFO] 后台进程 (PID: $savedPid) 已不存在" Yellow
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

# ---- Start background monitor ----
if ($Background) {
    if (Test-Path $pidFile) {
        $existPid = (Get-Content $pidFile -Raw).Trim()
        $existProc = Get-Process -Id $existPid -ErrorAction SilentlyContinue
        if ($existProc) {
            WC "  [WARN] 后台 Monitor 已在运行 (PID: $existPid)" Yellow
            WC "  如需重启，请先运行: .\auto-switch-key.ps1 -Stop" DarkGray
            exit 0
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    # Reason: -WindowStyle Hidden 让窗口不可见；-Monitor 进入循环监控
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Monitor -Interval $Interval -Threshold $Threshold"
    if ($DryRun) { $argList += " -DryRun" }
    $proc = Start-Process powershell -ArgumentList $argList -PassThru -WindowStyle Hidden
    $proc.Id | Set-Content $pidFile -Encoding UTF8

    Write-Host ""
    WC "  [Background] Monitor 已在后台启动 (PID: $($proc.Id))" Green
    WC "  Interval  : ${Interval}s" DarkGray
    WC "  Threshold : `$$Threshold" DarkGray
    WC "  PID file  : $pidFile" DarkGray
    WC "  停止命令  : .\auto-switch-key.ps1 -Stop" Cyan
    Write-Host ""
    Log "Background monitor started (PID: $($proc.Id), interval=${Interval}s, threshold=`$$Threshold)"
    exit 0
}

# Reason: -Interval 单独无意义，强制要求配合 -Monitor
if ($Interval -ne 300 -and -not $Monitor) {
    Write-Host ""
    WC "  [ERROR] -Interval 必须配合 -Monitor 使用" Red
    WC "  示例: .\auto-switch-key.ps1 -Monitor -Interval 60" DarkGray
    Write-Host ""
    exit 1
}


if ($Name -ieq "-ALL") {
    # Reason: -Name -ALL 查看所有 key 的详细信息，复用 api-checker.ps1 的并行查询模式
    $sep = "=" * 66
    $ts  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Host ""
    WC "+$sep+" Blue
    WC "|  API Key Detail (ALL)   [$($API_KEYS.Count) key(s)]   $ts" Blue
    WC "+$sep+" Blue

    if ($API_KEYS.Count -eq 1) {
        $entry = $API_KEYS[0]
        Write-Host ""
        WC "  [1/1] Querying: $($entry.Name)" DarkGray
        QueryKey -KeyName $entry.Name -Key $entry.Key -Dept $entry.Dept -Admin $entry.Admin
        WC "  All done." DarkGray
        Write-Host ""
        exit 0
    }

    WC "  Fetching all $($API_KEYS.Count) keys in parallel..." DarkGray

    # Phase 1: Resolve all key IDs in parallel
    $idRequests = @()
    foreach ($entry in $API_KEYS) {
        $idRequests += @{ Uri = "$API_BASE/apiStats/api/get-key-id"; Body = @{ apiKey = $entry.Key } }
    }
    $idResults = BatchApiPost -Requests $idRequests

    # Phase 2: Fetch stats AND model-stats in one batch
    $phase2Requests = @()
    $resolvedIndices = @()
    for ($i = 0; $i -lt $API_KEYS.Count; $i++) {
        if ($idResults[$i].Ok) {
            $apiId = $idResults[$i].Data.id
            $phase2Requests += @{ Uri = "$API_BASE/apiStats/api/user-stats"; Body = @{ apiId = $apiId } }
            $phase2Requests += @{ Uri = "$API_BASE/apiStats/api/user-model-stats"; Body = @{ apiId = $apiId; period = "daily" } }
            $resolvedIndices += $i
        }
    }
    $phase2Results = @()
    if ($phase2Requests.Count -gt 0) {
        $phase2Results = BatchApiPost -Requests $phase2Requests
    }

    # Build lookups (results alternate: stats, model, stats, model, ...)
    $statsLookup = @{}
    $modelLookup = @{}
    for ($j = 0; $j -lt $resolvedIndices.Count; $j++) {
        $idx = $resolvedIndices[$j]
        $statsLookup[$idx] = $phase2Results[$j * 2]
        $modelLookup[$idx] = $phase2Results[$j * 2 + 1]
    }

    # Render each key
    for ($i = 0; $i -lt $API_KEYS.Count; $i++) {
        $entry = $API_KEYS[$i]

        if (-not $idResults[$i].Ok) {
            $short = $entry.Key.Substring(0, 10) + "..." + $entry.Key.Substring($entry.Key.Length - 4)
            $s = "-" * 66
            Write-Host ""
            WC "  +$s+" Cyan
            WC "  | $($entry.Name)  ($short)" Cyan
            WC "  +$s+" Cyan
            WC "    [FAIL] Cannot resolve key: $($idResults[$i].Error)" Red
            continue
        }

        if (-not $statsLookup.ContainsKey($i) -or -not $statsLookup[$i].Ok) {
            $short = $entry.Key.Substring(0, 10) + "..." + $entry.Key.Substring($entry.Key.Length - 4)
            $s = "-" * 66
            Write-Host ""
            WC "  +$s+" Cyan
            WC "  | $($entry.Name)  ($short)" Cyan
            WC "  +$s+" Cyan
            $err = if ($statsLookup.ContainsKey($i)) { $statsLookup[$i].Error } else { "No stats" }
            WC "    [FAIL] Cannot get stats: $err" Red
            continue
        }

        QueryKey -KeyName $entry.Name -Key $entry.Key -Dept $entry.Dept -Admin $entry.Admin `
                 -PreStats $statsLookup[$i].Data -PreModel $modelLookup[$i]
    }

    WC "  All done." DarkGray
    Write-Host ""
    exit 0
} elseif ($Name) {
    $entry = $API_KEYS | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $entry) {
        Write-Host ""
        WC "  [ERROR] Key '$Name' not found. Available keys:" Red
        foreach ($k in $API_KEYS) { WC "    $($k.Name)" DarkGray }
        Write-Host ""
        exit 1
    }
    QueryKey -KeyName $entry.Name -Key $entry.Key -Dept $entry.Dept -Admin $entry.Admin
    exit 0
}

if ($Dashboard) {
    ShowDashboard
    exit 0
}

if ($Status) {
    ShowStatus
    exit 0
}

if ($Current) {
    ShowCurrentKey
    exit 0
}

if ($Monitor) {
    $sep = "=" * 60
    Write-Host ""
    WC "+$sep+" Blue
    WC "|  Claude Code API Key Auto-Switcher (Monitor)" Blue
    WC "+$sep+" Blue
    WC "  Interval  : ${Interval}s" DarkGray
    WC "  Threshold : `$$Threshold" DarkGray
    WC "  DryRun    : $DryRun" DarkGray
    WC "  Log file  : $logFile" DarkGray
    WC "  Press Ctrl+C to stop." DarkGray
    Write-Host ""
    Log "Monitor started: interval=${Interval}s, threshold=`$$Threshold"

    while ($true) {
        try {
            CheckAndSwitch
        } catch {
            WC "  [ERROR] $($_.Exception.Message)" Red
            Log "ERROR: $($_.Exception.Message)"
        }
        WC "  Next check in ${Interval}s..." DarkGray
        Start-Sleep -Seconds $Interval
    }
} else {
    # One-shot mode
    $sep = "=" * 60
    Write-Host ""
    WC "+$sep+" Blue
    WC "|  Claude Code API Key Auto-Switcher" Blue
    WC "+$sep+" Blue
    Write-Host ""

    try {
        [void](CheckAndSwitch)
    } catch {
        WC "  [ERROR] $($_.Exception.Message)" Red
        Log "ERROR: $($_.Exception.Message)"
        exit 1
    }
    Write-Host ""
}
