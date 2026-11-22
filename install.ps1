<#
.SYNOPSIS
    GameBudsKeepOn.ps1 を自動起動にする。

.DESCRIPTION
    順番に 2 つの方式を試す。上に通ればそれで終わる。

    方式 1: タスク スケジューラへ登録する。ログオン時に起動し、1 分ごとに繰り返す。
            常駐しないので電源管理に優しい。既定では管理者権限が必要だった。
    方式 2: 現在のユーザーのログイン時起動に登録する。常駐モードで動く。
            管理者権限が要らない。

    書き込みの経路は常駐の側が点検ごとに選ぶ。
    GG が動いていれば Engine、無ければ USB の HID へ直接書く。
    どちらの経路も管理者の権限は要らない。

.PARAMETER Minutes
    自動電源オフの分数。0 はなし。既定は 0。

.PARAMETER TaskName
    タスク スケジューラとログイン時起動に出す名前。既定は GameBudsKeepOn。

.PARAMETER IntervalSeconds
    常駐モードで点検する間隔の秒数。既定は 300、つまり 5 分。
    普段はこの間隔で寝る。
    起動の 1 回目は 10 秒後、接続に気づいた直後は 15 秒後と 45 秒後に点検する。
    間隔は、取り出してから書き込むまでの遅れの最大値でもある。
    本体が値を 0 へ戻しても、その前に書き込める長さにする。

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Minutes 0
    .\install.ps1 -Minutes 0 -IntervalSeconds 30
#>
#Requires -PSEdition Core

[CmdletBinding()]
param(
    # 0 から 1440 まで通す。0 はなし。
    # GG の画面に出る候補は 10 個だけだが、本体は候補に無い値も受ける。
    # 候補に無い値のときだけ警告が出る。
    [ValidateRange(0, 1440)]
    [int]$Minutes = 0,
    [string]$TaskName = 'GameBudsKeepOn',
    [int]$IntervalSeconds = 300
)

$ErrorActionPreference = 'Stop'

$Self = Split-Path -Parent $PSCommandPath
$Script = Join-Path $Self 'GameBudsKeepOn.ps1'
if (-not (Test-Path -LiteralPath $Script)) {
    throw "GameBudsKeepOn.ps1 が同じ場所に無い: $Script"
}

$Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $Pwsh) {
    throw 'PowerShell 7 が見つからない。インストールしてから実行してください。'
}

Write-Host "スクリプト   : $Script"
Write-Host "実行本体     : $($Pwsh.Source)"
Write-Host "自動電源オフ : $(if ($Minutes -eq 0) { 'なし' } else { "$Minutes 分" })"
Write-Host ''

# ---------- 方式 1: タスク スケジューラ ----------
$taskOk = $false
try {
    $ArgStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Minutes {1}' -f $Script, $Minutes
    $Action = New-ScheduledTaskAction -Execute $Pwsh.Source -Argument $ArgStr

    # 繰り返しは Once のトリガに付ける決まり。
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition

    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Settings $Settings -Principal $Principal `
        -Description "Arctis GameBuds の自動電源オフを $($Minutes) 分にそろえる。1 分ごと。" `
        -ErrorAction Stop | Out-Null

    # 応答を信じない。作り終わったあとで見付ける。
    # 実際に作られていないのに成功と出る場合があった。
    if ($null -eq (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw '登録したはずのタスクが見付からない'
    }

    $taskOk = $true
    Write-Host "登録しました: タスク スケジューラの $TaskName"
} catch {
    Write-Host "タスク スケジューラは使えませんでした: $($_.Exception.Message.Trim())"
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
        ForEach-Object { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
}

# ---------- 方式 2: ログイン時起動 ----------
$runOk = $false
if (-not $taskOk) {
    $RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $ArgStr = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Watch -Minutes {1} -IntervalSeconds {2}' `
        -f $Script, $Minutes, $IntervalSeconds
    $Value = '"{0}" {1}' -f $Pwsh.Source, $ArgStr

    if (-not (Test-Path -LiteralPath $RunKey)) {
        throw "ログイン時起動の場所が見付からない: $RunKey"
    }
    Set-ItemProperty -LiteralPath $RunKey -Name $TaskName -Value $Value -Type String
    # 昔の名前 GamebudSleep で登録した値が残れば合わせて外す。
    # 残るとログインで二重に起きる。
    Remove-ItemProperty -LiteralPath $RunKey -Name 'GamebudSleep' -ErrorAction SilentlyContinue
    $runOk = $true

    Write-Host "登録しました: ログイン時起動の $TaskName（常駐モード、$IntervalSeconds 秒ごと）"

    # 今すぐ動かす。ログオンを待たずに効くようにする。
    # -File で実行している物だけ止める。
    # この命令を打っているプロセス（-Command で入っている）は巻き込まない。
    Get-Process pwsh -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and $_.CommandLine -match 'gamebud-sleep\.ps1|GameBudsKeepOn\.ps1' -and
                       $_.CommandLine -like '*-File*' -and
                       $_.CommandLine -notlike '*-Command*' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $Pwsh.Source -WindowStyle Hidden -ArgumentList $ArgStr
    Write-Host '今すぐ動くように起動しました。'
}

Write-Host ''
Write-Host '確認:      Get-Content "$env:LOCALAPPDATA\GameBudsKeepOn\log.txt" -Tail 5'
Write-Host '手動実行:  .\GameBudsKeepOn.ps1 -DryRun'
if ($runOk) {
    Write-Host '常駐停止:  .\uninstall.ps1'
}
