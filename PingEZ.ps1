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
# $script: スコープで宣言することで Initialize-MainForm 返却後もイベントハンドラから参照できる
$script:LogBuffer   = [System.Text.StringBuilder]::new()
$script:txtTarget   = $null
$script:txtPort     = $null
$script:txtResult   = $null
$script:statusLabel = $null
$script:execButtons = @()
$script:setRunning  = $null
$script:setReady    = $null
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
            if ($num -ge 1 -and $num -le 65535) {
                $result += $num
            }
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
            "入力エラー",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
    return $true
}

function Test-PortsValid {
    param([string]$PortText, [int[]]$Ports)
    if ($PortText.Trim() -eq '') {
        [System.Windows.Forms.MessageBox]::Show(
            "ポートが入力されていません。`n例: 80,443,445,3389",
            "入力エラー",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }
    if ($Ports.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "有効なポート番号が見つかりません。`n1〜65535 の数値をカンマ区切りで入力してください。`n例: 80,443,445,3389",
            "入力エラー",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
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
        [System.Windows.Forms.TextBox]$ResultBox,
        [string]$Text
    )
    $script:LogBuffer.AppendLine($Text) | Out-Null
    $ResultBox.AppendText($Text + "`r`n")
    $ResultBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-Separator {
    param([System.Windows.Forms.TextBox]$ResultBox, [string]$Title = '')
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

#region ---- ping処理 ----
function Invoke-PingCheck {
    param(
        [string[]]$Targets,
        [System.Windows.Forms.TextBox]$ResultBox,
        [object]$StatusLabel
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Separator -ResultBox $ResultBox -Title "Ping 確認  [$timestamp]"

    foreach ($target in $Targets) {
        if (-not (Test-TargetSafe $target)) {
            Add-Result -ResultBox $ResultBox -Text "[$target]  スキップ: 不正な文字が含まれています"
            continue
        }

        $StatusLabel.Text = "実行中: ping → $target"
        [System.Windows.Forms.Application]::DoEvents()

        try {
            $pingResult = Test-Connection -ComputerName $target -Count 2 -ErrorAction Stop
            $avg = [math]::Round(($pingResult | Measure-Object -Property ResponseTime -Average).Average, 1)
            Add-Result -ResultBox $ResultBox -Text "[$target]  成功  応答時間: ${avg}ms"
        }
        catch {
            $msg = $_.Exception.Message
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
        [System.Windows.Forms.TextBox]$ResultBox,
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

            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $asyncResult = $client.BeginConnect($target, $port, $null, $null)
                $waited = $asyncResult.AsyncWaitHandle.WaitOne(3000)
                if ($waited -and $client.Connected) {
                    $client.EndConnect($asyncResult)
                    Add-Result -ResultBox $ResultBox -Text "[$target`:$port]  成功 (Open)"
                } else {
                    Add-Result -ResultBox $ResultBox -Text "[$target`:$port]  失敗 (Timeout or Refused)"
                }
                $client.Close()
            }
            catch {
                $msg = $_.Exception.Message
                Add-Result -ResultBox $ResultBox -Text "[$target`:$port]  失敗  $msg"
            }
        }
    }

    Add-Result -ResultBox $ResultBox -Text ""
    $StatusLabel.Text = "完了: TCP ポート確認"
}
#endregion

#region ---- tracert処理 ----
function Invoke-TracertCheck {
    param(
        [string[]]$Targets,
        [System.Windows.Forms.TextBox]$ResultBox,
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
            $argList = @('-d', '-h', '30', '-w', '1000', $target)
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo.FileName = 'tracert.exe'
            $proc.StartInfo.Arguments = $argList -join ' '
            $proc.StartInfo.UseShellExecute = $false
            $proc.StartInfo.RedirectStandardOutput = $true
            $proc.StartInfo.RedirectStandardError = $true
            $proc.StartInfo.CreateNoWindow = $true
            $proc.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(932)
            $proc.Start() | Out-Null

            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                Add-Result -ResultBox $ResultBox -Text $line
            }
            $proc.WaitForExit(60000) | Out-Null

            if (-not $proc.HasExited) {
                $proc.Kill()
                Add-Result -ResultBox $ResultBox -Text "[タイムアウト: tracert を強制終了しました]"
            }
        }
        catch {
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
        [System.Windows.Forms.TextBox]$ResultBox,
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
                $entry = [System.Net.Dns]::GetHostEntry($target)
                $hostName = $entry.HostName
                Add-Result -ResultBox $ResultBox -Text "[$target]  逆引き成功  → $hostName"
            } else {
                $entry = [System.Net.Dns]::GetHostEntry($target)
                $addresses = ($entry.AddressList | ForEach-Object { $_.ToString() }) -join ', '
                Add-Result -ResultBox $ResultBox -Text "[$target]  正引き成功  → $addresses"
            }
        }
        catch {
            $msg = $_.Exception.Message
            if ($isIP) {
                Add-Result -ResultBox $ResultBox -Text "[$target]  逆引き失敗  $msg"
            } else {
                Add-Result -ResultBox $ResultBox -Text "[$target]  正引き失敗  $msg"
            }
        }
    }

    Add-Result -ResultBox $ResultBox -Text ""
    $StatusLabel.Text = "完了: DNS 確認"
}
#endregion

#region ---- 保存処理 ----
function Save-Results {
    param(
        [object]$StatusLabel
    )

    if ($script:LogBuffer.Length -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "保存する結果がありません。",
            "情報",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $defaultName = "nwcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "結果を保存"
    $dialog.FileName = $defaultName
    $dialog.Filter = "テキストファイル (*.txt)|*.txt|CSVファイル (*.csv)|*.csv|すべてのファイル (*.*)|*.*"
    $dialog.FilterIndex = 1
    $dialog.DefaultExt = "txt"

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $filePath = $dialog.FileName

        try {
            $content = $script:LogBuffer.ToString()

            if ($filePath -like '*.csv') {
                $lines = $content -split "`r?`n"
                $csvLines = $lines | ForEach-Object {
                    '"' + $_.Replace('"', '""') + '"'
                }
                $csvLines | Out-File -FilePath $filePath -Encoding UTF8 -Force
            } else {
                $content | Out-File -FilePath $filePath -Encoding UTF8 -Force
            }

            $StatusLabel.Text = "保存完了: $filePath"
            [System.Windows.Forms.MessageBox]::Show(
                "結果を保存しました。`n$filePath",
                "保存完了",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        catch {
            $errMsg = $_.Exception.Message
            $StatusLabel.Text = "保存失敗"
            [System.Windows.Forms.MessageBox]::Show(
                "保存に失敗しました。`n$errMsg",
                "保存エラー",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
}
#endregion

#region ---- GUI初期化 ----
function Initialize-MainForm {

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PingEZ - ネットワーク疎通確認ツール  [確認専用 / 設定変更なし]"
    $form.Size = New-Object System.Drawing.Size(900, 720)
    $form.MinimumSize = New-Object System.Drawing.Size(750, 600)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Meiryo UI', 9)

    # ---- 左パネル (入力エリア) ----
    $panelLeft = New-Object System.Windows.Forms.Panel
    $panelLeft.Location = New-Object System.Drawing.Point(8, 8)
    $panelLeft.Size = New-Object System.Drawing.Size(230, 640)
    $panelLeft.Anchor = 'Top,Left,Bottom'
    $form.Controls.Add($panelLeft)

    # 宛先ラベル
    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = "宛先 (1行1件)"
    $lblTarget.Location = New-Object System.Drawing.Point(0, 0)
    $lblTarget.Size = New-Object System.Drawing.Size(230, 20)
    $lblTarget.Font = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelLeft.Controls.Add($lblTarget)

    $lblTargetHint = New-Object System.Windows.Forms.Label
    $lblTargetHint.Text = "IPアドレスまたはホスト名"
    $lblTargetHint.Location = New-Object System.Drawing.Point(0, 20)
    $lblTargetHint.Size = New-Object System.Drawing.Size(230, 18)
    $lblTargetHint.ForeColor = [System.Drawing.Color]::Gray
    $lblTargetHint.Font = New-Object System.Drawing.Font('Meiryo UI', 8)
    $panelLeft.Controls.Add($lblTargetHint)

    # $script: スコープで宣言 → Initialize-MainForm 返却後もイベントハンドラから参照可能
    $script:txtTarget = New-Object System.Windows.Forms.TextBox
    $script:txtTarget.Location = New-Object System.Drawing.Point(0, 40)
    $script:txtTarget.Size = New-Object System.Drawing.Size(228, 220)
    $script:txtTarget.Multiline = $true
    $script:txtTarget.ScrollBars = 'Vertical'
    $script:txtTarget.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:txtTarget.Text = "192.168.1.1`r`n192.168.1.254"
    $script:txtTarget.Anchor = 'Top,Left,Right'
    $panelLeft.Controls.Add($script:txtTarget)

    # ポートラベル
    $lblPort = New-Object System.Windows.Forms.Label
    $lblPort.Text = "TCPポート (カンマ区切り)"
    $lblPort.Location = New-Object System.Drawing.Point(0, 268)
    $lblPort.Size = New-Object System.Drawing.Size(230, 20)
    $lblPort.Font = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelLeft.Controls.Add($lblPort)

    $lblPortHint = New-Object System.Windows.Forms.Label
    $lblPortHint.Text = "例: 80,443,445,3389"
    $lblPortHint.Location = New-Object System.Drawing.Point(0, 288)
    $lblPortHint.Size = New-Object System.Drawing.Size(230, 18)
    $lblPortHint.ForeColor = [System.Drawing.Color]::Gray
    $lblPortHint.Font = New-Object System.Drawing.Font('Meiryo UI', 8)
    $panelLeft.Controls.Add($lblPortHint)

    $script:txtPort = New-Object System.Windows.Forms.TextBox
    $script:txtPort.Location = New-Object System.Drawing.Point(0, 308)
    $script:txtPort.Size = New-Object System.Drawing.Size(228, 22)
    $script:txtPort.Text = "80,443,445,3389"
    $script:txtPort.Font = New-Object System.Drawing.Font('Consolas', 9)
    $panelLeft.Controls.Add($script:txtPort)

    # ---- ボタン群 (ローカル変数で良い。フォームが参照を保持する) ----
    $btnY = 346
    $btnSize = New-Object System.Drawing.Size(228, 32)
    $btnGap = 38

    $btnPing = New-Object System.Windows.Forms.Button
    $btnPing.Text = "Ping 確認"
    $btnPing.Location = New-Object System.Drawing.Point(0, $btnY)
    $btnPing.Size = $btnSize
    $btnPing.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnPing.ForeColor = [System.Drawing.Color]::White
    $btnPing.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnPing)

    $btnTcp = New-Object System.Windows.Forms.Button
    $btnTcp.Text = "TCP ポート確認"
    $btnTcp.Location = New-Object System.Drawing.Point(0, ($btnY + $btnGap * 1))
    $btnTcp.Size = $btnSize
    $btnTcp.BackColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $btnTcp.ForeColor = [System.Drawing.Color]::White
    $btnTcp.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnTcp)

    $btnTracert = New-Object System.Windows.Forms.Button
    $btnTracert.Text = "Tracert 確認"
    $btnTracert.Location = New-Object System.Drawing.Point(0, ($btnY + $btnGap * 2))
    $btnTracert.Size = $btnSize
    $btnTracert.BackColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $btnTracert.ForeColor = [System.Drawing.Color]::White
    $btnTracert.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnTracert)

    $btnDns = New-Object System.Windows.Forms.Button
    $btnDns.Text = "DNS 確認"
    $btnDns.Location = New-Object System.Drawing.Point(0, ($btnY + $btnGap * 3))
    $btnDns.Size = $btnSize
    $btnDns.BackColor = [System.Drawing.Color]::FromArgb(16, 110, 190)
    $btnDns.ForeColor = [System.Drawing.Color]::White
    $btnDns.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnDns)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "結果クリア"
    $btnClear.Location = New-Object System.Drawing.Point(0, ($btnY + $btnGap * 4 + 10))
    $btnClear.Size = $btnSize
    $btnClear.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $btnClear.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnClear)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "結果を保存 (TXT/CSV)"
    $btnSave.Location = New-Object System.Drawing.Point(0, ($btnY + $btnGap * 5 + 10))
    $btnSave.Size = $btnSize
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 153, 76)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'
    $panelLeft.Controls.Add($btnSave)

    # ---- 右パネル (結果エリア) ----
    $panelRight = New-Object System.Windows.Forms.Panel
    $panelRight.Location = New-Object System.Drawing.Point(248, 8)
    $panelRight.Size = New-Object System.Drawing.Size(630, 640)
    $panelRight.Anchor = 'Top,Left,Right,Bottom'
    $form.Controls.Add($panelRight)

    $lblResult = New-Object System.Windows.Forms.Label
    $lblResult.Text = "実行結果"
    $lblResult.Location = New-Object System.Drawing.Point(0, 0)
    $lblResult.Size = New-Object System.Drawing.Size(630, 20)
    $lblResult.Font = New-Object System.Drawing.Font('Meiryo UI', 9, [System.Drawing.FontStyle]::Bold)
    $panelRight.Controls.Add($lblResult)

    $script:txtResult = New-Object System.Windows.Forms.TextBox
    $script:txtResult.Location = New-Object System.Drawing.Point(0, 22)
    $script:txtResult.Size = New-Object System.Drawing.Size(628, 580)
    $script:txtResult.Multiline = $true
    $script:txtResult.ScrollBars = 'Both'
    $script:txtResult.ReadOnly = $true
    $script:txtResult.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:txtResult.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $script:txtResult.ForeColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $script:txtResult.WordWrap = $false
    $script:txtResult.Anchor = 'Top,Left,Right,Bottom'
    $panelRight.Controls.Add($script:txtResult)

    # ---- ステータスバー ----
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:statusLabel.Text = "準備完了 - 宛先を入力して実行ボタンを押してください"
    $script:statusLabel.Spring = $true
    $script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusStrip.Items.Add($script:statusLabel) | Out-Null
    $form.Controls.Add($statusStrip)

    # ---- ボタン一括制御スクリプトブロック ----
    $script:execButtons = @($btnPing, $btnTcp, $btnTracert, $btnDns)

    $script:setRunning = {
        foreach ($b in $script:execButtons) { $b.Enabled = $false }
    }
    $script:setReady = {
        foreach ($b in $script:execButtons) { $b.Enabled = $true }
    }

    # ---- イベントハンドラ ----
    # $script: 変数を直接参照するため GetNewClosure() は不要

    $btnPing.Add_Click({
        $targets = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $targets)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: Ping 確認..."
        try {
            Invoke-PingCheck -Targets $targets -ResultBox $script:txtResult -StatusLabel $script:statusLabel
        } catch {
            $script:statusLabel.Text = "エラー: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Ping処理中にエラーが発生しました。`n$($_.Exception.Message)", "エラー", 'OK', 'Error') | Out-Null
        }
        & $script:setReady
    })

    $btnTcp.Add_Click({
        $targets = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $targets)) { return }
        $ports = Get-Ports -PortText $script:txtPort.Text
        if (-not (Test-PortsValid -PortText $script:txtPort.Text -Ports $ports)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: TCP ポート確認..."
        try {
            Invoke-TcpCheck -Targets $targets -Ports $ports -ResultBox $script:txtResult -StatusLabel $script:statusLabel
        } catch {
            $script:statusLabel.Text = "エラー: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("TCP確認中にエラーが発生しました。`n$($_.Exception.Message)", "エラー", 'OK', 'Error') | Out-Null
        }
        & $script:setReady
    })

    $btnTracert.Add_Click({
        $targets = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $targets)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: Tracert 確認... (時間がかかる場合があります)"
        try {
            Invoke-TracertCheck -Targets $targets -ResultBox $script:txtResult -StatusLabel $script:statusLabel
        } catch {
            $script:statusLabel.Text = "エラー: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Tracert処理中にエラーが発生しました。`n$($_.Exception.Message)", "エラー", 'OK', 'Error') | Out-Null
        }
        & $script:setReady
    })

    $btnDns.Add_Click({
        $targets = Get-Targets -TextBox $script:txtTarget
        if (-not (Test-TargetsNotEmpty $targets)) { return }
        & $script:setRunning
        $script:statusLabel.Text = "実行中: DNS 確認..."
        try {
            Invoke-DnsCheck -Targets $targets -ResultBox $script:txtResult -StatusLabel $script:statusLabel
        } catch {
            $script:statusLabel.Text = "エラー: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("DNS確認中にエラーが発生しました。`n$($_.Exception.Message)", "エラー", 'OK', 'Error') | Out-Null
        }
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

    return $form
}
#endregion

#region ---- エントリポイント ----
try {
    $mainForm = Initialize-MainForm
    [System.Windows.Forms.Application]::Run($mainForm)
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "ツールの起動中にエラーが発生しました。`n$($_.Exception.Message)",
        "起動エラー",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
#endregion
