#Requires -Version 5.1
<#
.SYNOPSIS
    PingEZ - ネットワーク疎通確認ツール (確認専用)
.DESCRIPTION
    ping / TCPポート確認 / tracert / DNS確認 を GUI から実行できる管理者向けツール。
    ネットワーク設定の変更は一切行いません。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

#region ---- グローバル変数 ----
$script:LogBuffer   = [System.Text.StringBuilder]::new()
$script:txtTarget   = $null
$script:txtPort     = $null
$script:txtResult   = $null
$script:statusLabel = $null
$script:execButtons = @()
$script:setRunning  = $null
$script:setReady    = $null

$script:PortServices = @{
    20 = 'FTP-data';  21 = 'FTP';        22 = 'SSH';       23 = 'Telnet'
    25 = 'SMTP';      53 = 'DNS';         80 = 'HTTP';     110 = 'POP3'
   119 = 'NNTP';     143 = 'IMAP';       161 = 'SNMP';    162 = 'SNMP-Trap'
   389 = 'LDAP';     443 = 'HTTPS';      445 = 'SMB';     465 = 'SMTPS'
   514 = 'Syslog';   587 = 'Submission'; 636 = 'LDAPS';   993 = 'IMAPS'
   995 = 'POP3S';   1433 = 'MSSQL';    1521 = 'Oracle';  3306 = 'MySQL'
  3389 = 'RDP';     5432 = 'PostgreSQL'; 5985 = 'WinRM-HTTP'; 5986 = 'WinRM-HTTPS'
  8080 = 'HTTP-Alt'; 8443 = 'HTTPS-Alt'; 9100 = 'JetDirect'
}
#endregion

#region ---- 入力取得 ----
function Get-Targets {
    param([System.Windows.Forms.TextBox]$TextBox)
    $TextBox.Lines | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
}

function Get-Ports {
    param([string]$PortText)
    $result = @()
    foreach ($p in ($PortText -split ',')) {
        $trimmed = $p.Trim()
        if ($trimmed -match '^\d+$') {
            $num = [int]$trimmed
            if ($num -ge 1 -and $num -le 65535) { $result += $num }
        }
    }
    return $result
}
#endregion

#region ---- 入力チェック ----
function Test-TargetsNotEmpty {
    param([string[]]$Targets)
    if (-not $Targets -or $Targets.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "宛先が入力されていません。`n1行に1件、IPアドレスまたはホスト名を入力してください。",
            "入力エラー", 'OK', 'Warning') | Out-Null
        return $false
    }
    return $true
}

function Test-PortsValid {
    param([string]$PortText, [int[]]$Ports)
    if ($PortText.Trim() -eq '') {
        [System.Windows.Forms.MessageBox]::Show(
            "ポートが入力されていません。`n例: 80,443,445,3389",
            "入力エラー", 'OK', 'Warning') | Out-Null
        return $false
    }
    if ($Ports.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "有効なポート番号が見つかりません。`n1〜65535 の数値をカンマ区切りで入力してください。",
            "入力エラー", 'OK', 'Warning') | Out-Null
        return $false
    }
    return $true
}

function Test-TargetSafe {
    param([string]$Target)
    return $Target -match '^[a-zA-Z0-9.\-_:]+$'
}
#endregion

#region ---- 結果追記 ----
function Add-Result {
    param(
        [System.Windows.Forms.RichTextBox]$ResultBox,
        [string]$Text
    )
    $script:LogBuffer.AppendLine($Text) | Out-Null

    $color = if     ($Text -match '成功')                { [System.Drawing.Color]::FromArgb(80,  220, 100) }
             elseif ($Text -match 'タイムアウト|ICMP 無応答') { [System.Drawing.Color]::FromArgb(255, 210,  60) }
             elseif ($Text -match '失敗|エラー')           { [System.Drawing.Color]::FromArgb(255, 110, 110) }
             elseif ($Text -match 'スキップ')              { [System.Drawing.Color]::FromArgb(255, 170,  60) }
             elseif ($Text -match '^={3,}')               { [System.Drawing.Color]::FromArgb(80,  180, 255) }
             else                                         { [System.Drawing.Color]::FromArgb(200, 230, 200) }

    $ResultBox.SelectionStart  = $ResultBox.TextLength
    $ResultBox.SelectionLength = 0
    $ResultBox.SelectionColor  = $color
    $ResultBox.AppendText($Text + "`r`n")
    $ResultBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-Separator {
    param([System.Windows.Forms.RichTextBox]$ResultBox, [string]$Title = '')
    $line = '=' * 60
    if ($Title) {
        Add-Result -ResultBox $ResultBox -Text "`r`n$line"
        Add-Result -ResultBox $ResultBox -Text "  $Title"
        Add-Result -ResultBox $ResultBox -Text $line
    } else {
        Add-Result -ResultBox $ResultBox -Text $line
    }
}
#endregion

#region ---- Ping処理 ----
function Invoke-PingCheck {
    param(
        [string[]]$Targets,
        [System.Windows.Forms.RichTextBox]$ResultBox,
        [object]$StatusLabel
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Separator -ResultBox $ResultBox -Title "Ping 確認  [$timestamp]"

    $buffer  = [byte[]](1..32)
    $options = New-Object System.Net.NetworkInformation.PingOptions

    foreach ($target in $Targets) {
        if (-not (Test-TargetSafe $target)) {
            Add-Result -ResultBox $ResultBox -Text "[$target]  スキップ: 不正な文字が含まれています"
            continue
        }
        $StatusLabel.Text = "実行中: ping → $target"
        [System.Windows.Forms.Application]::DoEvents()

        $ping = New-Object System.Net.NetworkInformation.Ping
        $successCount = 0; $totalTime = 0; $lastStatus = $null; $errMsg = $null

        for ($i = 0; $i -lt 2; $i++) {
            try {
                $reply      = $ping.Send($target, 2000, $buffer, $options)
                $lastStatus = $reply.Status
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $successCount++
                    $totalTime += $reply.RoundtripTime
                }
            } catch {
                $inner  = $_.Exception.InnerException
                $errMsg = if ($inner) { $inner.Message } else { $_.Exception.Message }
                break
            }
        }
        $ping.Dispose()

        if ($errMsg) {
            Add-Result -ResultBox $ResultBox -Text "[$target]  失敗  $errMsg"
        } elseif ($successCount -gt 0) {
            $avg = [math]::Round($totalTime / $successCount, 1)
            Add-Result -ResultBox $ResultBox -Text "[$target]  成功  応答時間: ${avg}ms"
        } else {
            $msg = switch ($lastStatus.ToString()) {
                'TimedOut'                      { 'タイムアウト' }
                'DestinationHostUnreachable'     { '宛先ホスト到達不可' }
                'DestinationNetworkUnreachable'  { '宛先ネットワーク到達不可' }
                'DestinationUnreachable'         { '宛先到達不可' }
                'NoResources'                   { 'リソース不足 (ネットワーク輻輳)' }
                'TtlExpired'                    { 'TTL 超過' }
                'IcmpError'                     { 'ICMP エラー' }
                default                         { $lastStatus.ToString() }
            }
            Add-Result -ResultBox $ResultBox -Text "[$target]  失敗  $msg"
        }
    }
    Add-Result -ResultBox $ResultBox -Text ""
    $StatusLabel.Text = "完了: Ping 確認"
}
#endregion

#region ---- TCPポート確認処理 ----
function Invoke-TcpCheck {
    param(
        [string[]]$Targets,
        [int[]]$Ports,
        [System.Windows.Forms.RichTextBox]$ResultBox,
        [object]$StatusLabel
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Separator -ResultBox $ResultBox -Title "TCP ポート確認  [$timestamp]"

    foreach ($target in $Targets) {
        if (-not (Test-TargetSafe $target)) {
            Add-Result -ResultBox $ResultBox -Text "[$target]  スキップ: 不正な文字が含まれています"
            continue
        }
        foreach ($port in $Ports) {
            $StatusLabel.Text = "実行中: TCP $target`:$port"
            [System.Windows.Forms.Application]::DoEvents()

            $svc    = if ($script:PortServices.ContainsKey($port)) { "  ($($script:PortServices[$port]))" } else { '' }
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $client.BeginConnect($target, $port, $null, $null)
                if (-not $ar.AsyncWaitHandle.WaitOne(3000)) {
                    Add-Result -ResultBox $ResultBox -Text "[$target`:$port]$svc  失敗 (タイムアウト - 応答なし)"
                } else {
                    try {
                        $client.EndConnect($ar)
                        Add-Result -ResultBox $ResultBox -Text "[$target`:$port]$svc  成功 (Open)"
                    } catch [System.Net.Sockets.SocketException] {
                        if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
                            Add-Result -ResultBox $ResultBox -Text "[$target`:$port]$svc  失敗 (Refused - ポート閉鎖)"
                        } else {
                            Add-Result -ResultBox $ResultBox -Text "[$target`:$port]$svc  失敗  $($_.Exception.Message)"
                        }
                    }
                }
            } catch {
                Add-Result -ResultBox $ResultBox -Text "[$target`:$port]$svc  失敗  $($_.Exception.Message)"
            } finally {
                $client.Close()
            }
        }
    }
    Add-Result -ResultBox $ResultBox -Text ""
    $StatusLabel.Text = "完了: TCP ポート確認"
}
#endregion

#region ---- Tracert処理 ----
function Invoke-TracertCheck {
    param(
        [string[]]$Targets,
        [System.Windows.Forms.RichTextBox]$ResultBox,
        [object]$StatusLabel
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Separator -ResultBox $ResultBox -Title "Tracert 確認  [$timestamp]"

    foreach ($target in $Targets) {
        if (-not (Test-TargetSafe $target)) {
            Add-Result -ResultBox $ResultBox -Text "[$target]  スキップ: 不正な文字が含まれています"
            continue
        }
        Add-Result -ResultBox $ResultBox -Text "--- tracert: $target ---"
        $StatusLabel.Text = "実行中: tracert → $target  (時間がかかる場合があります)"
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo.FileName               = 'tracert.exe'
            $proc.StartInfo.Arguments              = (@('-d', '-h', '30', '-w', '1000', $target) -join ' ')
            $proc.StartInfo.UseShellExecute        = $false
            $proc.StartInfo.RedirectStandardOutput = $true
            $proc.StartInfo.RedirectStandardError  = $true
            $proc.StartInfo.CreateNoWindow         = $true
            $proc.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(932)
            $proc.Start() | Out-Null

            $prevBlank = $false
            $hopCount  = 0

            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) {
                    if (-not $prevBlank) { Add-Result -ResultBox $ResultBox -Text ""; $prevBlank = $true }
                    continue
                }
                $prevBlank = $false
                if ($line -match '^\s+\d+\s+') {
                    $hopCount++
                    if ($line -match '\*\s+\*\s+\*') {
                        Add-Result -ResultBox $ResultBox -Text "$line  ← ICMP 無応答"
                    } else {
                        Add-Result -ResultBox $ResultBox -Text $line
                    }
                } else {
                    Add-Result -ResultBox $ResultBox -Text $line
                }
            }
            $proc.WaitForExit(60000) | Out-Null
            if (-not $proc.HasExited) {
                $proc.Kill()
                Add-Result -ResultBox $ResultBox -Text "[タイムアウト: tracert を強制終了しました]"
            }
            if ($hopCount -gt 0) {
                Add-Result -ResultBox $ResultBox -Text "  [経由ホップ数: $hopCount]"
            }
        } catch {
            Add-Result -ResultBox $ResultBox -Text "[エラー] tracert 実行失敗: $($_.Exception.Message)"
        }
        Add-Result -ResultBox $ResultBox -Text ""
    }
    $StatusLabel.Text = "完了: Tracert 確認"
}
#endregion

#region ---- DNS確認処理 ----
function Invoke-DnsCheck {
    param(
        [string[]]$Targets,
        [System.Windows.Forms.RichTextBox]$ResultBox,
        [object]$StatusLabel
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Separator -ResultBox $ResultBox -Title "DNS 確認  [$timestamp]"

    foreach ($target in $Targets) {
        if (-not (Test-TargetSafe $target)) {
            Add-Result -ResultBox $ResultBox -Text "[$target]  スキップ: 不正な文字が含まれています"
            continue
        }
        $StatusLabel.Text = "実行中: DNS → $target"
        [System.Windows.Forms.Application]::DoEvents()

        $isIP = $target -match '^\d{1,3}(\.\d{1,3}){3}$'
        try {
            if ($isIP) {
                $entry    = [System.Net.Dns]::GetHostEntry($target)
                $hostName = $entry.HostName
                if ($hostName -eq $target) {
                    Add-Result -ResultBox $ResultBox -Text "[$target]  逆引き  PTR レコードなし"
                } else {
                    Add-Result -ResultBox $ResultBox -Text "[$target]  逆引き成功  → $hostName"
                }
            } else {
                $entry     = [System.Net.Dns]::GetHostEntry($target)
                $addresses = ($entry.AddressList | ForEach-Object { $_.ToString() }) -join ', '
                if ($addresses) {
                    Add-Result -ResultBox $ResultBox -Text "[$target]  正引き成功  → $addresses"
                } else {
                    Add-Result -ResultBox $ResultBox -Text "[$target]  正引き  IPv4 アドレスなし (AAAA レコードのみの可能性)"
                }
            }
        } catch {
            $inner = $_.Exception.InnerException
            $msg   = if ($inner) { $inner.Message } else { $_.Exception.Message }
            $dir   = if ($isIP) { '逆引き' } else { '正引き' }
            Add-Result -ResultBox $ResultBox -Text "[$target]  ${dir}失敗  $msg"
        }
    }
    Add-Result -ResultBox $ResultBox -Text ""
    $StatusLabel.Text = "完了: DNS 確認"
}
#endregion

#region ---- 全確認処理 ----
function Invoke-AllChecks {
    param(
        [string[]]$Targets,
        [int[]]$Ports,
        [System.Windows.Forms.RichTextBox]$ResultBox,
        [object]$StatusLabel
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Separator -ResultBox $ResultBox -Title "全確認  [$timestamp]"
    Invoke-PingCheck -Targets $Targets -ResultBox $ResultBox -StatusLabel $StatusLabel
    Invoke-TcpCheck  -Targets $Targets -Ports $Ports -ResultBox $ResultBox -StatusLabel $StatusLabel
    Invoke-DnsCheck  -Targets $Targets -ResultBox $ResultBox -StatusLabel $StatusLabel
    $StatusLabel.Text = "完了: 全確認 (Ping / TCP / DNS)"
}
#endregion

#region ---- 保存処理 ----
function Save-Results {
    param([object]$StatusLabel)

    if ($script:LogBuffer.Length -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("保存する結果がありません。", "情報", 'OK', 'Information') | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title      = "結果を保存"
    $dialog.FileName   = "nwcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $dialog.Filter     = "テキストファイル (*.txt)|*.txt|CSVファイル (*.csv)|*.csv|すべてのファイル (*.*)|*.*"
    $dialog.FilterIndex = 1
    $dialog.DefaultExt = "txt"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $content = $script:LogBuffer.ToString()
            if ($dialog.FileName -like '*.csv') {
                ($content -split "`r?`n") |
                    ForEach-Object { '"' + $_.Replace('"', '""') + '"' } |
                    Out-File -FilePath $dialog.FileName -Encoding UTF8 -Force
            } else {
                $content | Out-File -FilePath $dialog.FileName -Encoding UTF8 -Force
            }
            $StatusLabel.Text = "保存完了: $($dialog.FileName)"
            [System.Windows.Forms.MessageBox]::Show("結果を保存しました。`n$($dialog.FileName)", "保存完了", 'OK', 'Information') | Out-Null
        } catch {
            $StatusLabel.Text = "保存失敗"
            [System.Windows.Forms.MessageBox]::Show("保存に失敗しました。`n$($_.Exception.Message)", "保存エラー", 'OK', 'Error') | Out-Null
        }
    }
}
#endregion

#region ---- 宛先リスト保存/読込 ----
function Save-TargetList {
    param([object]$StatusLabel)
    if ([string]::IsNullOrWhiteSpace($script:txtTarget.Text)) {
        [System.Windows.Forms.MessageBox]::Show("宛先が入力されていません。", "情報", 'OK', 'Information') | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title      = "宛先リストを保存"
    $dialog.FileName   = "targets_$(Get-Date -Format 'yyyyMMdd')"
    $dialog.Filter     = "テキストファイル (*.txt)|*.txt|すべてのファイル (*.*)|*.*"
    $dialog.DefaultExt = "txt"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:txtTarget.Lines |
                Where-Object { $_.Trim() -ne '' } |
                Out-File -FilePath $dialog.FileName -Encoding UTF8 -Force
            $StatusLabel.Text = "宛先リストを保存しました: $($dialog.FileName)"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("保存に失敗しました。`n$($_.Exception.Message)", "保存エラー", 'OK', 'Error') | Out-Null
        }
    }
}

function Load-TargetList {
    param([object]$StatusLabel)
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title  = "宛先リストを読み込む"
    $dialog.Filter = "テキストファイル (*.txt)|*.txt|すべてのファイル (*.*)|*.*"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $lines = Get-Content -Path $dialog.FileName -Encoding UTF8 -ErrorAction Stop |
                Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') }
            $script:txtTarget.Text = ($lines -join "`r`n")
            $StatusLabel.Text = "宛先リストを読み込みました ($($lines.Count) 件)"
        } catch {
            [System.Windows.Forms.MessageBox]::Show("読み込みに失敗しました。`n$($_.Exception.Message)", "読み込みエラー", 'OK', 'Error') | Out-Null
        }
    }
}
#endregion

#region ---- GUI初期化 ----
function Initialize-MainForm {

    $form = New-Object System.Windows.Forms.Form
    $form.Text         = "PingEZ - ネットワーク疎通確認ツール  [確認専用 / 設定変更なし]"
    $form.Size         = New-Object System.Drawing.Size(920, 730)
    $form.MinimumSize  = New-Object System.Drawing.Size(750, 600)
    $form.StartPosition = 'CenterScreen'
    $form.Font         = New-Object System.Drawing.Font('Meiryo UI', 9)

    # ---- 左パネル ----
    $panelLeft = New-Object System.Windows.Forms.Panel
    $panelLeft.Location = New-Object System.Drawing.Point(8, 8)
    $panelLeft.Size     = New-Object System.Drawing.Size(232, 660)
    $panelLeft.Anchor   = 'Top,Left,Bottom'
    $form.Controls.Add($panelLeft)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "宛先 (1行1件)"
    $lbl.Location = New-Object System.Drawing.Point(0, 0)
    $lbl.Size     = New-Object System.Drawing.Size(232, 20)
    $lbl.Font     = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelLeft.Controls.Add($lbl)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text      = "IPアドレスまたはホスト名"
    $lblHint.Location  = New-Object System.Drawing.Point(0, 20)
    $lblHint.Size      = New-Object System.Drawing.Size(232, 18)
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $lblHint.Font      = New-Object System.Drawing.Font('Meiryo UI', 8)
    $panelLeft.Controls.Add($lblHint)

    $script:txtTarget = New-Object System.Windows.Forms.TextBox
    $script:txtTarget.Location   = New-Object System.Drawing.Point(0, 40)
    $script:txtTarget.Size       = New-Object System.Drawing.Size(230, 175)
    $script:txtTarget.Multiline  = $true
    $script:txtTarget.ScrollBars = 'Vertical'
    $script:txtTarget.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $script:txtTarget.Text       = ""
    $panelLeft.Controls.Add($script:txtTarget)

    # 宛先リスト 読込 / 保存 (横並び小ボタン)
    $btnListLoad = New-Object System.Windows.Forms.Button
    $btnListLoad.Text      = "リスト読込"
    $btnListLoad.Location  = New-Object System.Drawing.Point(0, 220)
    $btnListLoad.Size      = New-Object System.Drawing.Size(113, 24)
    $btnListLoad.FlatStyle = 'Flat'
    $btnListLoad.Font      = New-Object System.Drawing.Font('Meiryo UI', 8)
    $panelLeft.Controls.Add($btnListLoad)

    $btnListSave = New-Object System.Windows.Forms.Button
    $btnListSave.Text      = "リスト保存"
    $btnListSave.Location  = New-Object System.Drawing.Point(117, 220)
    $btnListSave.Size      = New-Object System.Drawing.Size(113, 24)
    $btnListSave.FlatStyle = 'Flat'
    $btnListSave.Font      = New-Object System.Drawing.Font('Meiryo UI', 8)
    $panelLeft.Controls.Add($btnListSave)

    $lblPort = New-Object System.Windows.Forms.Label
    $lblPort.Text     = "TCPポート (カンマ区切り)"
    $lblPort.Location = New-Object System.Drawing.Point(0, 252)
    $lblPort.Size     = New-Object System.Drawing.Size(232, 20)
    $lblPort.Font     = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelLeft.Controls.Add($lblPort)

    $lblPortHint = New-Object System.Windows.Forms.Label
    $lblPortHint.Text      = "例: 80,443,445,3389"
    $lblPortHint.Location  = New-Object System.Drawing.Point(0, 272)
    $lblPortHint.Size      = New-Object System.Drawing.Size(232, 18)
    $lblPortHint.ForeColor = [System.Drawing.Color]::Gray
    $lblPortHint.Font      = New-Object System.Drawing.Font('Meiryo UI', 8)
    $panelLeft.Controls.Add($lblPortHint)

    $script:txtPort = New-Object System.Windows.Forms.TextBox
    $script:txtPort.Location = New-Object System.Drawing.Point(0, 292)
    $script:txtPort.Size     = New-Object System.Drawing.Size(230, 22)
    $script:txtPort.Text     = "80,443,445,3389"
    $script:txtPort.Font     = New-Object System.Drawing.Font('Consolas', 9)
    $panelLeft.Controls.Add($script:txtPort)

    # ---- 確認ボタン群 ----
    $bY = 326; $bH = 30; $bG = 35; $bW = 230

    $btnPing = New-Object System.Windows.Forms.Button
    $btnPing.Text      = "Ping 確認"
    $btnPing.Location  = New-Object System.Drawing.Point(0, $bY)
    $btnPing.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnPing.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnPing.ForeColor = [System.Drawing.Color]::White
    $btnPing.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnPing)

    $btnTcp = New-Object System.Windows.Forms.Button
    $btnTcp.Text      = "TCP ポート確認"
    $btnTcp.Location  = New-Object System.Drawing.Point(0, ($bY + $bG))
    $btnTcp.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnTcp.BackColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $btnTcp.ForeColor = [System.Drawing.Color]::White
    $btnTcp.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnTcp)

    $btnTracert = New-Object System.Windows.Forms.Button
    $btnTracert.Text      = "Tracert 確認"
    $btnTracert.Location  = New-Object System.Drawing.Point(0, ($bY + $bG * 2))
    $btnTracert.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnTracert.BackColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $btnTracert.ForeColor = [System.Drawing.Color]::White
    $btnTracert.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnTracert)

    $btnDns = New-Object System.Windows.Forms.Button
    $btnDns.Text      = "DNS 確認"
    $btnDns.Location  = New-Object System.Drawing.Point(0, ($bY + $bG * 3))
    $btnDns.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnDns.BackColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $btnDns.ForeColor = [System.Drawing.Color]::White
    $btnDns.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnDns)

    # 全確認ボタン
    $yAll = $bY + $bG * 3 + $bH + 10
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text      = "全確認 (Ping / TCP / DNS)"
    $btnAll.Location  = New-Object System.Drawing.Point(0, $yAll)
    $btnAll.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnAll.BackColor = [System.Drawing.Color]::FromArgb(100, 60, 180)
    $btnAll.ForeColor = [System.Drawing.Color]::White
    $btnAll.FlatStyle = 'Flat'
    $btnAll.Font      = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelLeft.Controls.Add($btnAll)

    $yClear = $yAll + $bH + 12
    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text      = "結果クリア"
    $btnClear.Location  = New-Object System.Drawing.Point(0, $yClear)
    $btnClear.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnClear.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $btnClear.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnClear)

    $ySave = $yClear + $bH + 5
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text      = "結果を保存 (TXT/CSV)"
    $btnSave.Location  = New-Object System.Drawing.Point(0, $ySave)
    $btnSave.Size      = New-Object System.Drawing.Size($bW, $bH)
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 153, 76)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnSave)

    # ---- 右パネル (RichTextBox) ----
    $panelRight = New-Object System.Windows.Forms.Panel
    $panelRight.Location = New-Object System.Drawing.Point(250, 8)
    $panelRight.Size     = New-Object System.Drawing.Size(648, 660)
    $panelRight.Anchor   = 'Top,Left,Right,Bottom'
    $form.Controls.Add($panelRight)

    $lblResult = New-Object System.Windows.Forms.Label
    $lblResult.Text     = "実行結果"
    $lblResult.Location = New-Object System.Drawing.Point(0, 0)
    $lblResult.Size     = New-Object System.Drawing.Size(648, 20)
    $lblResult.Font     = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelRight.Controls.Add($lblResult)

    $script:txtResult = New-Object System.Windows.Forms.RichTextBox
    $script:txtResult.Location    = New-Object System.Drawing.Point(0, 22)
    $script:txtResult.Size        = New-Object System.Drawing.Size(646, 600)
    $script:txtResult.ReadOnly    = $true
    $script:txtResult.Font        = New-Object System.Drawing.Font('Consolas', 9)
    $script:txtResult.BackColor   = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:txtResult.ForeColor   = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $script:txtResult.WordWrap    = $false
    $script:txtResult.ScrollBars  = [System.Windows.Forms.RichTextBoxScrollBars]::Both
    $script:txtResult.Anchor      = 'Top,Left,Right,Bottom'
    $panelRight.Controls.Add($script:txtResult)

    # ---- ステータスバー ----
    $strip = New-Object System.Windows.Forms.StatusStrip
    $script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:statusLabel.Text      = "準備完了 - 宛先を入力して実行ボタンを押してください"
    $script:statusLabel.Spring    = $true
    $script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $strip.Items.Add($script:statusLabel) | Out-Null
    $form.Controls.Add($strip)

    # ---- ボタン一括制御 ----
    $script:execButtons = @($btnPing, $btnTcp, $btnTracert, $btnDns, $btnAll)
    $script:setRunning  = { foreach ($b in $script:execButtons) { $b.Enabled = $false } }
    $script:setReady    = { foreach ($b in $script:execButtons) { $b.Enabled = $true  } }

    # ---- イベントハンドラ ----
    $btnPing.Add_Click({
        $t = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $t)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: Ping 確認..."
        try { Invoke-PingCheck -Targets $t -ResultBox $script:txtResult -StatusLabel $script:statusLabel }
        catch { $script:statusLabel.Text = "エラー"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "エラー", 'OK', 'Error') | Out-Null }
        & $script:setReady
    })

    $btnTcp.Add_Click({
        $t = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $t)) { return }
        $p = Get-Ports -PortText $script:txtPort.Text
        if (-not (Test-PortsValid -PortText $script:txtPort.Text -Ports $p)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: TCP ポート確認..."
        try { Invoke-TcpCheck -Targets $t -Ports $p -ResultBox $script:txtResult -StatusLabel $script:statusLabel }
        catch { $script:statusLabel.Text = "エラー"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "エラー", 'OK', 'Error') | Out-Null }
        & $script:setReady
    })

    $btnTracert.Add_Click({
        $t = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $t)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: Tracert 確認..."
        try { Invoke-TracertCheck -Targets $t -ResultBox $script:txtResult -StatusLabel $script:statusLabel }
        catch { $script:statusLabel.Text = "エラー"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "エラー", 'OK', 'Error') | Out-Null }
        & $script:setReady
    })

    $btnDns.Add_Click({
        $t = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $t)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: DNS 確認..."
        try { Invoke-DnsCheck -Targets $t -ResultBox $script:txtResult -StatusLabel $script:statusLabel }
        catch { $script:statusLabel.Text = "エラー"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "エラー", 'OK', 'Error') | Out-Null }
        & $script:setReady
    })

    $btnAll.Add_Click({
        $t = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $t)) { return }
        $p = Get-Ports -PortText $script:txtPort.Text
        if (-not (Test-PortsValid -PortText $script:txtPort.Text -Ports $p)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: 全確認 (Ping / TCP / DNS)..."
        try { Invoke-AllChecks -Targets $t -Ports $p -ResultBox $script:txtResult -StatusLabel $script:statusLabel }
        catch { $script:statusLabel.Text = "エラー"; [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "エラー", 'OK', 'Error') | Out-Null }
        & $script:setReady
    })

    $btnClear.Add_Click({
        $script:txtResult.Clear()
        $script:LogBuffer.Clear() | Out-Null
        $script:statusLabel.Text = "結果をクリアしました"
    })

    $btnSave.Add_Click({
        Save-Results -StatusLabel $script:statusLabel
    })

    $btnListLoad.Add_Click({
        Load-TargetList -StatusLabel $script:statusLabel
    })

    $btnListSave.Add_Click({
        Save-TargetList -StatusLabel $script:statusLabel
    })

    return $form
}
#endregion

#region ---- エントリポイント ----
try {
    $mainForm = Initialize-MainForm
    [System.Windows.Forms.Application]::Run($mainForm)
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "ツールの起動中にエラーが発生しました。`n$($_.Exception.Message)",
        "起動エラー", 'OK', 'Error') | Out-Null
}
#endregion
