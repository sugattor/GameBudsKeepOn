<#
.SYNOPSIS
    自動起動を取り除く。

.DESCRIPTION
    タスク スケジューラの登録と、ログイン時起動の両方を外す。
    常駐しているプロセスも止める。
    ログと状態のファイルは残す。残りまで消すなら -RemoveLog を付ける。

.PARAMETER TaskName
    登録したときの名前。既定は GameBudsKeepOn。

.PARAMETER RemoveLog
    ログと状態のファイルも消す。

.EXAMPLE
    .\uninstall.ps1
    .\uninstall.ps1 -RemoveLog
#>
#Requires -PSEdition Core

[CmdletBinding()]
param(
    [string]$TaskName = 'GameBudsKeepOn',
    [switch]$RemoveLog
)

$ErrorActionPreference = 'Stop'

# ---------- タスク スケジューラ ----------
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
    Write-Host 'タスク スケジューラの登録は無い'
} else {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "タスク スケジューラの登録を外した: $TaskName"
}

# ---------- ログイン時起動 ----------
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$prop = Get-ItemProperty -LiteralPath $RunKey -Name $TaskName -ErrorAction SilentlyContinue
if ($null -eq $prop) {
    Write-Host 'ログイン時起動の登録は無い'
} else {
    Remove-ItemProperty -LiteralPath $RunKey -Name $TaskName
    # 昔の名前 GamebudSleep で登録した値が残れば合わせて外す。
    Remove-ItemProperty -LiteralPath $RunKey -Name 'GamebudSleep' -ErrorAction SilentlyContinue
    Write-Host "ログイン時起動を外した: $TaskName"
}

# ---------- 常駐しているプロセス ----------
# -File で実行している物だけ止める。
# このファイルの名前を含んだ命令を打っているプロセス（-Command で入っている）を巻き込まない。
$killed = @(Get-Process pwsh -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $PID -and
                   $_.CommandLine -match 'gamebud-sleep\.ps1|GameBudsKeepOn\.ps1' -and
                   $_.CommandLine -like '*-File*' -and
                   $_.CommandLine -notlike '*-Command*' })
if ($killed.Count -eq 0) {
    Write-Host '常駐しているプロセスは無い'
} else {
    $killed | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "常駐を止めた: $($killed.Count) 件"
}

# ---------- ログ ----------
if ($RemoveLog) {
    $dir = Join-Path $env:LOCALAPPDATA 'GameBudsKeepOn'
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Host "ログも消した: $dir"
    }
    # 昔の名前 GamebudSleep の記録場も消す。
    $oldDir = Join-Path $env:LOCALAPPDATA 'GamebudSleep'
    if (Test-Path -LiteralPath $oldDir) {
        Remove-Item -LiteralPath $oldDir -Recurse -Force
        Write-Host "昔の名前の記録も消した: $oldDir"
    }
}

Write-Host ''
Write-Host '注意: 端末側の自動電源オフは、書き換えたまま残っている。'
Write-Host '今の値を見る: .\GameBudsKeepOn.ps1 -DryRun'
