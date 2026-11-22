#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ドングルと PC のあいだの USB のやり取りを取り込む。

.DESCRIPTION
    SteelSeries Engine を通さず、USB の実物だけを捉えるための足場。
    管理者として実行しないと、USBPcap の管理デバイスが開けない。
    実測でアクセス拒否が出ている。

    取り込みの形は 4 つ。上のものが優先される。
      -HidWatch 秒   HID で状態を問い続ける
      -HidWrite 分   HID で自動電源オフを書き込む
      -WriteValues   Engine 経由で値を順に書き込む
      どれでもない   画面の指示どおりイヤホンを出し入れする

    取り込んだ pcap の読み下ろしは tools\usb-report.py。
    実測で分かったことは analysis\findings-api.md の 15 節と 16 節。

    注記について。
      -I は取り込みの旗ではない。機器の識別を読み出す一回限りの動きだった。
      6 つのハブすべてで Found standard HWID と出て、取り込み自体は始まらない。
      USB 3.0 のハブもそのまま捉えられた（実測で hub2 に 137752 バイト残った）。

.EXAMPLE
    # 管理者として開いた PowerShell で
    .\capture-usb.ps1
    # 取り込み中に、画面の指示どおりイヤホンを出し入れする

.EXAMPLE
    # 管理者として開いた PowerShell で。HID だけの書き込みを見る
    .\capture-usb.ps1 -OutDir ..\capture\usb3 -HidWrite 45

.EXAMPLE
    # 管理者として開いた PowerShell で。HID の問いが続いているか見る
    .\capture-usb.ps1 -OutDir ..\capture\usb4 -HidWatch 16
#>
[CmdletBinding()]
param(
    # 既定の採取先は、この道具のある場所の 1 つ上の capture\usb
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'capture\usb'),
    [int]$Seconds = 60,
    # 出し入れをやめて、この順に値を書き込むだけにする。
    # 同じ命令が出るか確かめるための確認運転。
    # 空白とカンマで区切る。 Start-Process 経由ではカンマが消えるため、文字列で受ける。
    [string]$WriteValues = '',
    # 書き込みのあいだの間隔
    [int]$GapSeconds = 9,
    # 書き込みの代わりに HID の探見本を走らせる。
    # Engine の並びと比べるのが目的。0 以上でこの形に切り替わる。
    [int]$HidWrite = -1,
    # HID の探見本で状態を問い続ける時間。
    # 問いが USB に出ているか確かめるための形。0 以上でこの形に切り替わる。
    [int]$HidWatch = -1,
    [string]$HidProbe = (Join-Path $PSScriptRoot 'hid-dongle.ps1')
)

$Values = @($WriteValues -split '[ ,]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })

$ErrorActionPreference = 'Stop'

$UsbPcap = 'C:\Program Files\USBPcap\USBPcapCMD.exe'
$App     = (Join-Path (Split-Path $PSScriptRoot) 'GameBudsKeepOn.ps1')

if (-not (Test-Path -LiteralPath $UsbPcap)) {
    throw "USBPcap が見つからない: $UsbPcap"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$Mark = Join-Path $OutDir 'time.txt'
Set-Content -LiteralPath $Mark -Value ('開始 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')) -Encoding utf8

# 管理者の窓は閉じると何も残らない。全部ファイルへ書き写す。
Start-Transcript -Path (Join-Path $OutDir 'transcript.txt') -Force | Out-Null

function Mark {
    param([string]$Text)
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Text
    Add-Content -LiteralPath $Mark -Value $line -Encoding utf8
    Write-Host $line
}

# 開ける管理デバイスを数える。無い番号は取り込みを開始できない。
# 注意: 0xC0000000 は PowerShell で負の整数として扱われる。
# P/Invoke 側を符号付き整数で受け取る宣言にしておくと壊れない。
$k32 = Add-Type -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(
    string name, int access, int share, IntPtr sa, int mode, int flags, IntPtr tpl);
'@ -Name 'Win32File' -Namespace 'Cap' -PassThru

$devices = @()
foreach ($n in 1..8) {
    $h = $k32::CreateFile("\\.\USBPcap$n", -1073741824, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($null -ne $h -and -not $h.IsInvalid) {
        $devices += "\\.\USBPcap$n"
        $h.Close()
    }
}
if ($devices.Count -eq 0) {
    throw 'USBPcap の管理デバイスが開けない。管理者として実行しているか確かめてください。'
}
Write-Host ('管理デバイス: ' + ($devices -join ', '))

# 取り込みを開始する。USBPcapCMD は Enter で止まる作りなので、
# 標準入力を開いたままにして、時間を過ぎたら止める。
$jobs = @()
$files = @()
foreach ($d in $devices) {
    $tag = ($d -replace '.*USBPcap', 'hub')
    $out = Join-Path $OutDir ("$tag.pcap")
    $files += $out
    # 注意: -I は捕捉の旗ではない。注記の鍵を作るだけで終わる。
    # この PC のハブはすべて標準の HWID なので、-I は要らない（実測）。
    $argLine = "-d $d -o `"$out`" -A -b 8388608 -s 8192"
    # -NoNewWindow と -WindowStyle は同時に指定できない。
    $p = Start-Process -FilePath $UsbPcap -ArgumentList $argLine `
                       -PassThru -NoNewWindow
    if ($null -ne $p) { $jobs += $p }
}
if ($jobs.Count -eq 0) {
    throw 'USBPcapCMD が起動しなかった。'
}
Start-Sleep -Seconds 3
$alive = @($jobs | Where-Object { -not $_.HasExited })
if ($alive.Count -eq 0) {
    throw 'USBPcapCMD がすぐ終わった。管理者で開いても捕捉できない可能性がある。'
}
Mark "取り込み開始 $($alive.Count) 本（うち $($jobs.Count - $alive.Count) 本は空きハブ）"

if ($HidWatch -ge 0) {
    # HID で状態を問い続けているあいだ、USB の実物を取り込む。
    Mark "HID で $HidWatch 秒 問い続ける"
    Start-Sleep -Seconds 4
    $pwshSelf = (Get-Process -Id $PID).Path
    & $pwshSelf -NoProfile -ExecutionPolicy Bypass -File $HidProbe -Do 監視 -Seconds $HidWatch -ReadWaitMs 1200 2>&1 |
        ForEach-Object { Mark ('    ' + $_) }
    Start-Sleep -Seconds 3
} elseif ($HidWrite -ge 0) {
    # HID の探見本を別プロセスで走らせる（同じプロセスで走らせると
    # 探見本の時間切れ終了が取り込みまで巻き込む）。
    Mark 'HID の探見本を走らせる'
    Start-Sleep -Seconds 6
    $pwshSelf = (Get-Process -Id $PID).Path
    Mark '  1 状態を読む'
    & $pwshSelf -NoProfile -ExecutionPolicy Bypass -File $HidProbe -Do 状態 -ReadCount 4 -TimeoutMs 4000 2>&1 |
        ForEach-Object { Mark ('    ' + $_) }
    Start-Sleep -Seconds 3
    Mark "  2 HID で $HidWrite 分を書く"
    & $pwshSelf -NoProfile -ExecutionPolicy Bypass -File $HidProbe -Do 書込 -Minutes $HidWrite -ReadCount 4 -TimeoutMs 4000 2>&1 |
        ForEach-Object { Mark ('    ' + $_) }
    Start-Sleep -Seconds 5
} elseif ($Values.Count -gt 0) {
    # 確認運転：同じ命令が値を変えて出るかを確かめる。
    Mark '確認運転: 値だけを変えて書き込む'
    Start-Sleep -Seconds 6
    foreach ($v in $Values) {
        Mark "  $v 分を書き込む"
        try {
            & $App -Minutes $v -Force
            Mark '    呼んだ'
        } catch {
            Mark "    失敗: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $GapSeconds
    }
} else {
    Mark '1 何もしない 10 秒'
    Start-Sleep -Seconds 10

    Mark '2 Engine 経由で書き込む'
    try {
        & $App -Minutes 30 -Force
        Mark '  書き込みを呼んだ'
    } catch {
        Mark "  書き込みが失敗: $($_.Exception.Message)"
    }

    Mark '3 ピープが鳴ります。イヤホンをケースへ入れて 10 秒、それから出してください'
    [Console]::Beep(880, 500)
    Mark '   40 秒のあいだにやってください'
    Start-Sleep -Seconds 40

    Mark '4 何もしない 10 秒'
    Start-Sleep -Seconds 10
}

foreach ($j in $jobs) {
    if ($null -ne $j -and -not $j.HasExited) { $j.Kill() }
}
Mark '取り込み停止'

Mark '=== 出来たもの ==='
foreach ($f in $files) {
    if (Test-Path -LiteralPath $f) {
        Mark ('  {0}  {1} バイト' -f (Split-Path -Leaf $f), (Get-Item -LiteralPath $f).Length)
    } else {
        Mark "  $(Split-Path -Leaf $f)  無し"
    }
}
Mark "時刻の記録: $Mark"
Stop-Transcript | Out-Null
Write-Host '0 バイト近いファイルは、そのハブに traffic が無い。ドングルは USB 3.0 のハブに出る。'
