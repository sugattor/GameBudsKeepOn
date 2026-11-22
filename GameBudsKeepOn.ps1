<#
.SYNOPSIS
    Arctis GameBuds の自動電源オフを、決め値にそろえる。

.DESCRIPTION
    経路は二つ。どちらも管理者の権限は要らない。

    1. SteelSeries GG の Engine が開いているローカル API
       GG が動いているときだけ使える。
       GG の手元に保存されている設定も同時に直す。
    2. USB の HID へ直接書く
       GG が無くても動く。ドングルへ 64 バイトのレポートを 1 本送る。

    経路の選び方（既定は Auto）。
      GG のプロセスが居て、API のポートが見つかれば 1。
      それ以外は 2。

    実測で分かった制約。
      読み取りは 1 プロセスで 1 回だけ通る。
      同じプロセスで 2 回読むと、2 回目以降は返事が来ない。
      だから読み取りは、この実行の中で 1 回にする。
      書き込み後の確かめは、次の実行で分かる。
      書き込みは同じプロセスで繰り返しても USB に出る（10 本すべて実測）。

    Engine API の手順（GG の画面の「保存」と同じ 2 回送り）。
      1. GET  /v1/connectedDevices                 接続中か見る
      2. GET  /device/<ID>/configurations          設定を読む
      3. PUT  /configuration/<設定ID>              分数だけ書き換える
      4. POST /configuration/<設定ID>/forceDeploy  有効化する
      5. GET  /device/<ID>/configurations          読み直して確かめる

    Engine API ではまった穴。
      POST /configuration/liveDeploy  中身が空の応答を返すが、何も変わらない
      POST /configuration             更新ではなく新規作成になり、設定が増える
      POST /configuration/<ID>/deploy エラーになる。forceDeploy を使う
      PUT の直後                      active が 0 に外れる

    HID の手順。
      1. 命令を送るチャネル（mi_03）を開く
      2. キューを空にする
      3. 0xb0 を送る。レポートの 12 番目のバイトが分数
      4. 分数が合わなければ 0xc1 と分数のバイトを送る
      5. ハンドルを閉じる

.PARAMETER Minutes
    自動電源オフの分数。0 はなし。既定は 0。

.PARAMETER Channel
    経路。Auto、Engine、Hid の 3 つ。既定は Auto。

.PARAMETER Force
    すでに決め値でも書き直す。

.PARAMETER DryRun
    読むだけで書き込まない。

.EXAMPLE
    .\GameBudsKeepOn.ps1 -DryRun
    .\GameBudsKeepOn.ps1 -Minutes 0
    .\GameBudsKeepOn.ps1 -Channel Hid -Minutes 30
#>
#Requires -PSEdition Core

[CmdletBinding()]
param(
    # GG の画面に出る候補は 10 個だけ。
    # それでも本体は候補に無い値をそのまま受ける。3 分を入れて 181 秒で切れた。
    # だから広く通し、GG の候補に無い値のときだけ警告を出す。
    [ValidateRange(0, 1440)]
    [int]$Minutes = 0,
    [string]$BaseUrl = '',
    [ValidateSet('Auto', 'Engine', 'Hid')]
    [string]$Channel = 'Auto',
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Engine の API のポートは、再起動のたびに変わる。実測で確かめた。
# 2026-11-22 の朝は 64255、同じ日の再起動後は 60845 だった。
# だからポートを決め打ちせず、点検のたびに探す。
$script:BaseUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $null } else { $BaseUrl }

$DeviceName = 'arctis_gamebuds_dongle'
$LogDir     = Join-Path $env:LOCALAPPDATA 'GameBudsKeepOn'
$LogFile    = Join-Path $LogDir 'log.txt'
$StateFile  = Join-Path $LogDir 'state.txt'
$MaxLogByte = 512 * 1024

# HID の機器の識別。ドングルは 3 つのチャネルを出す。
# 命令を受け付けるチャネルは mi_03（実測で wIndex=3）。
$HidMatch  = 'vid_1038&pid_230a'
$HidIface  = 'mi_03'
# 受け取りのバッファは一番長いレポートに合わせて取る。
# 64 バイトのバッファだと 512 バイトのレポートで止まる（実測）。
$HidBufLen = 513

# ==================================================================
# 記録
# ==================================================================

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $LogFile) -and
        ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogByte)) {
        Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
    }
}

function Write-Log {
    param([string]$Text)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    Write-Information $line
}

# 状態をファイルに覚えて、変わる瞬間だけログに残す。
# 点検を繰り返してもログが膨らまないようにするため。
function Write-State {
    param([string]$State)
    $old = $null
    if (Test-Path -LiteralPath $StateFile) {
        $old = (Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue)
    }
    if ($old -ne $State) {
        Set-Content -LiteralPath $StateFile -Value $State -Encoding utf8 -NoNewline
        return $true
    }
    return $false
}

function Format-Minutes {
    param($Value)
    if ($null -eq $Value) { return '不明' }
    if ($Value -eq 0) { return 'なし' }
    return "$Value 分"
}

# ==================================================================
# 経路 1: SteelSeries GG の Engine API
# ==================================================================

# Engine は自己署名の証明書を出す。検証を捨てる。
# PowerShell 7 の -SkipCertificateCheck を使う。
function Test-EngineEndpoint {
    param([int]$Port)

    # /v1/connectedDevices が JSON で返るポートが、Engine の API である。
    # 他のポートは 404 か、SSL が通らないので区別できる。実測で確かめた。
    try {
        $u = ("https://127.0.0.1:{0}/v1/connectedDevices" -f $Port)
        $r = Invoke-WebRequest -Uri $u -SkipCertificateCheck `
              -Headers @{ Origin = ("https://127.0.0.1:{0}" -f $Port); Accept = 'application/json' } `
              -TimeoutSec 4 -ErrorAction Stop
        return ([int]$r.StatusCode -eq 200 -and $r.Content -match '"devices"')
    } catch {
        return $false
    }
}

function Find-BaseUrl {
    # SteelSeries のプログラムが待ち受けているポートを順に試す。
    $ids = @(Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -like 'SteelSeries*' } |
             ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { return $null }

    $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object { $ids -contains $_.OwningProcess } |
               Select-Object -ExpandProperty LocalPort -Unique)

    foreach ($p in $ports) {
        if (Test-EngineEndpoint -Port $p) {
            return ("https://127.0.0.1:{0}" -f $p)
        }
    }
    return $null
}

function Ensure-Endpoint {
    if ($script:BaseUrl) { return $true }
    $u = Find-BaseUrl
    if ($null -eq $u) { return $false }
    $script:BaseUrl = $u
    Write-Log ("状態=ポート発見 " + $u)
    return $true
}

function Invoke-Api {
    param(
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE')]
        [string]$Method,
        [string]$Path,
        $Body
    )

    $opt = @{
        Uri                  = $script:BaseUrl + $Path
        Method               = $Method
        SkipCertificateCheck = $true
        Headers              = @{ Origin = $script:BaseUrl; Accept = 'application/json' }
        TimeoutSec           = 20
        ErrorAction          = 'Stop'
    }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body }
                else { $Body | ConvertTo-Json -Depth 12 -Compress }
        $opt.Body       = $json
        # charset を付けると Engine は弾く。application/json ぴったりが要る。
        $opt.ContentType = 'application/json'
    }

    try {
        $r = Invoke-WebRequest @opt
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            # 接続そのものができない。ポートが動いた可能性が高い。
            # 次の点検で探し直させる。
            $script:BaseUrl = $null
            throw
        }
        $status = [int]$resp.StatusCode
        $text = ''
        try {
            $text = $_.ErrorDetails.Message
            if ([string]::IsNullOrEmpty($text)) {
                $sr = [System.IO.StreamReader]::new($resp.GetResponseStream())
                $text = $sr.ReadToEnd()
            }
        } catch { }
        return [pscustomobject]@{ Status = $status; Body = $text }
    }
}

function Get-ConnectedDevice {
    $r = Invoke-Api GET '/v1/connectedDevices'
    if ($r.Status -ne 200) { return $null }
    foreach ($d in @(($r.Body | ConvertFrom-Json).devices)) {
        if ($d.name -eq $DeviceName -and [int]$d.connected -eq 1) { return $d }
    }
    return $null
}

function Get-ActiveConfig {
    param([int]$DeviceId)
    $r = Invoke-Api GET ("/device/{0}/configurations" -f $DeviceId)
    if ($r.Status -ne 200) { throw "設定取得に失敗 HTTP $($r.Status)" }
    $cfgs = @(($r.Body | ConvertFrom-Json).configurations)
    if ($cfgs.Count -eq 0) { throw '設定が 1 件も無い' }
    $active = @($cfgs | Where-Object { [int]$_.active -eq 1 })
    if ($active.Count -gt 0) { return $active[0] }
    return $cfgs[0]
}

function Get-CurrentMinutes {
    param($Config)
    $s = $Config.settings | ConvertFrom-Json
    if ($null -eq $s.inactivity_timer) { return $null }
    return [int]$s.inactivity_timer.minutes
}

function Set-CurrentMinutes {
    param($Config, [int]$DeviceId, [int]$Value)

    $s = $Config.settings | ConvertFrom-Json
    if ($null -eq $s.inactivity_timer) {
        $s | Add-Member -NotePropertyName inactivity_timer `
                        -NotePropertyValue ([pscustomobject]@{ minutes = $Value })
    } else {
        $s.inactivity_timer.minutes = $Value
    }

    # settings は JSON の文字列として渡す。
    # オブジェクトのまま渡すと通らない。
    $settingsJson = $s | ConvertTo-Json -Depth 40 -Compress
    $name = if ([string]::IsNullOrEmpty($Config.name)) { 'Default' }
            else { [string]$Config.name }
    $body = [ordered]@{
        id        = [string]$Config.id
        device_id = $DeviceId
        name      = $name
        settings  = $settingsJson
    }

    $r = Invoke-Api PUT ("/configuration/{0}" -f $Config.id) $body
    if ($r.Status -ne 200 -or $r.Body -match '"error"') {
        throw "PUT 失敗 HTTP $($r.Status) $($r.Body)"
    }

    # PUT の後に有効化が外れる。forceDeploy が必須。
    $r = Invoke-Api POST ("/configuration/{0}/forceDeploy" -f $Config.id) ([ordered]@{})
    if ($r.Status -ne 200 -or $r.Body -match '"error"') {
        Write-Log "forceDeploy が失敗したが値は入った可能性が高い: HTTP $($r.Status) $($r.Body)"
    }
}

function Get-DeviceSignature {
    param([int]$DeviceId)

    # 本体に直接問い合わせる。GET /device/<ID> は Engine の手元のコピーで、
    # イヤホンをしまってもしばらく接続済みのままなので使えない。
    # 返ってくる文字列の 5 番目に、イヤホンのファームウェアのバージョンが入る。
    # 居ないときは 0.0.0 になる。実測で確かめた。
    $r = Invoke-Api POST ("/device/{0}/function/get_fw_version" -f $DeviceId) -Body '{}'
    if ($r.Status -ne 200) { return '不明' }
    try {
        $v = ($r.Body | ConvertFrom-Json).function_data
        if ([string]::IsNullOrWhiteSpace([string]$v)) { return '不明' }
        return [string]$v
    } catch {
        return '不明'
    }
}

function Test-BudsPresent {
    param([string]$Signature)

    if ($Signature -eq '不明') { return $false }
    $slots = $Signature -split '/'
    if ($slots.Count -lt 6) { return $false }
    return $slots[4] -notin @('0', '0.0.0', '')
}

# ==================================================================
# 経路 2: USB の HID へ直接
# ==================================================================

if (-not ('Gamebud.Hid' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Gamebud {
public static class Hid {
    const int DIGCF_PRESENT = 0x02;
    const int DIGCF_DEVICEINTERFACE = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    public struct DID {
        public int Size;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("hid.dll", SetLastError = true)]
    public static extern void HidD_GetHidGuid(out Guid g);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SetupDiGetClassDevs(ref Guid g, string enumerator, IntPtr parent, int flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInterfaces(IntPtr hdi, IntPtr devInfo, ref Guid g, int idx, ref DID did);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr hdi, ref DID did, IntPtr detail, int detailSize, out int needed, IntPtr devInfo);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr hdi);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern SafeFileHandle CreateFile(string name, int access, int share, IntPtr sa, int mode, int flags, IntPtr template);

    [StructLayout(LayoutKind.Sequential)]
    public struct OV {
        public IntPtr Internal;
        public IntPtr InternalHigh;
        public IntPtr Offset;
        public IntPtr OffsetHigh;
        public IntPtr Event;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(SafeFileHandle h, byte[] buf, int len, out int read, ref OV ov);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetOverlappedResult(SafeFileHandle h, ref OV ov, out int read, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CancelIoEx(SafeFileHandle h, IntPtr ov);

    // 重複読み取り。時間で切れる。
    // 同期読み取りはデータが無い限り待ったまま返らない（実測）。
    public static byte[] ReadTimeout(SafeFileHandle h, int len, int ms, out int err) {
        err = 0;
        byte[] buf = new byte[len];
        ManualResetEvent ev = new ManualResetEvent(false);
        OV ov = new OV();
        ov.Event = ev.SafeWaitHandle.DangerousGetHandle();
        int read = 0;
        bool ok = ReadFile(h, buf, len, out read, ref ov);
        if (!ok) {
            err = Marshal.GetLastWin32Error();
            if (err != 997) {              // 997 = 実行中。これは正常。
                return null;
            }
            if (!ev.WaitOne(ms)) {
                CancelIoEx(h, IntPtr.Zero);
                err = 258;                 // 258 = 時間切れ
                return null;
            }
            if (!GetOverlappedResult(h, ref ov, out read, false)) {
                err = Marshal.GetLastWin32Error();
                return null;
            }
        }
        if (read <= 0) { return null; }
        byte[] got = new byte[read];
        Array.Copy(buf, got, read);
        return got;
    }

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetOutputReport(SafeFileHandle h, byte[] buf, int len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_FlushQueue(SafeFileHandle h);

    // 詰まっても必ず終わるようにする。点検は待ったまま残ってはいけない。
    public static void Watchdog(int ms) {
        Thread t = new Thread(() => {
            Thread.Sleep(ms);
            Console.Error.WriteLine("時間切れで終えた");
            Environment.Exit(3);
        });
        t.IsBackground = true;
        t.Start();
    }

    public static System.Collections.Generic.List<string> Enumerate() {
        System.Collections.Generic.List<string> res = new System.Collections.Generic.List<string>();
        Guid g;
        HidD_GetHidGuid(out g);
        IntPtr hdi = SetupDiGetClassDevs(ref g, null, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (hdi == IntPtr.Zero || hdi == new IntPtr(-1)) { return res; }
        for (int i = 0; ; i++) {
            DID did = new DID();
            did.Size = Marshal.SizeOf(typeof(DID));
            if (!SetupDiEnumDeviceInterfaces(hdi, IntPtr.Zero, ref g, i, ref did)) { break; }
            int needed;
            SetupDiGetDeviceInterfaceDetail(hdi, ref did, IntPtr.Zero, 0, out needed, IntPtr.Zero);
            if (needed <= 0) { continue; }
            IntPtr buf = Marshal.AllocHGlobal(needed);
            try {
                // 文字列版の作りでは cbSize は 8。文字列は 4 番目から始まる。
                Marshal.WriteInt32(buf, 8);
                if (!SetupDiGetDeviceInterfaceDetail(hdi, ref did, buf, needed, out needed, IntPtr.Zero)) { continue; }
                res.Add(Marshal.PtrToStringUni((IntPtr)((long)buf + 4)));
            } finally {
                Marshal.FreeHGlobal(buf);
            }
        }
        SetupDiDestroyDeviceInfoList(hdi);
        return res;
    }
}
}
'@
}

function Find-HidPath {
    $paths = @([Gamebud.Hid]::Enumerate() | Where-Object { $_ -like "*$HidMatch*" })
    if ($paths.Count -eq 0) { return $null }
    $pref = @($paths | Where-Object { $_ -like "*$HidIface*" })
    if ($pref.Count -gt 0) { return $pref[0] }
    return $paths[0]
}

function Open-Hid([string]$Path) {
    # 読み書き両方。他のプログラムと共有する（GG が開いていても開ける）。
    # 重複読み取りを使うので FILE_FLAG_OVERLAPPED を付ける。
    $h = [Gamebud.Hid]::CreateFile($Path, -1073741824, 3, [IntPtr]::Zero, 3, 1073741824, [IntPtr]::Zero)
    if ($h.IsInvalid) { return $null }
    return $h
}

function Send-HidReport($h, [byte[]]$Payload) {
    # レポート ID 0 を先頭に付ける。実測で GG と同じ形。
    $buf = New-Object byte[] 65
    $buf[0] = 0
    [Array]::Copy($Payload, 0, $buf, 1, [Math]::Min(64, $Payload.Length))
    $ok = [Gamebud.Hid]::HidD_SetOutputReport($h, $buf, $buf.Length)
    return [pscustomobject]@{ 成功 = $ok; 失敗 = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
}

# 一度だけ読んで、今の状態を返す。
# 読み取りは 1 プロセスで 1 回だけ通るので、ここは 1 回しか呼ばない。
function Read-HidStatus {
    $path = Find-HidPath
    if ($null -eq $path) {
        return [pscustomobject]@{ 見つかる = $false; 返事 = $false;
                                  接続 = $null; 分 = $null; 電池 = ''; 状態 = '機器が無い' }
    }
    $h = Open-Hid $path
    if ($null -eq $h) {
        return [pscustomobject]@{ 見つかる = $true; 返事 = $false;
                                  接続 = $null; 分 = $null; 電池 = ''; 状態 = '開けない' }
    }
    try {
        [Gamebud.Hid]::HidD_FlushQueue($h) | Out-Null
        Send-HidReport $h ([byte[]]@(0xb0, 0x00)) | Out-Null
        $err = 0
        $r = [Gamebud.Hid]::ReadTimeout($h, $HidBufLen, 3000, [ref]$err)
        if ($null -eq $r -or $r.Length -lt 13 -or $r[1] -ne 0xb0) {
            return [pscustomobject]@{ 見つかる = $true; 返事 = $false;
                                      接続 = $null; 分 = $null; 電池 = ''; 状態 = "返事なし=$err" }
        }
        # 4番目と5番目はイヤホンの状態。3 は取り出して接続（実測）。
        # 6番目と7番目は電池。12番目が自動電源オフの分数。
        $connected = ($r[4] -eq 3 -and $r[5] -eq 3)
        return [pscustomobject]@{
            経路     = 'Hid'
            見つかる = $true
            返事     = $true
            接続     = $connected
            分       = [int]$r[12]
            電池     = ('{0},{1}' -f $r[6], $r[7])
            状態     = ('{0:x2},{1:x2}' -f $r[4], $r[5])
        }
    } finally {
        $h.Close()
    }
}

function Write-HidMinutes {
    param([int]$Value)

    if ($Value -gt 255) {
        throw ('HID で送れる分数は 255 まで。目標={0}' -f $Value)
    }
    $path = Find-HidPath
    if ($null -eq $path) { throw 'HID の機器が見つからない（ドングルが刺さっていない）' }
    $h = Open-Hid $path
    if ($null -eq $h) { throw 'HID のハンドルが開けない' }
    try {
        # GG は同じ命令を 2 回送る。同じ形にする。
        $payload = [byte[]]@(0xc1, [byte]$Value)
        $w1 = Send-HidReport $h $payload
        Start-Sleep -Milliseconds 60
        $w2 = Send-HidReport $h $payload
        if (-not $w1.成功 -and -not $w2.成功) {
            throw ('HID の書き込みが失敗 GetLastError={0}' -f $w2.失敗)
        }
        return $true
    } finally {
        $h.Close()
    }
}

# ==================================================================
# 点検 1 回
# ==================================================================

# 点検の結果の 1 行。画面へ出す。
function Report-Poll {
    param(
        [string]$経路,
        $接続,
        $現在,
        [bool]$書いた
    )
    $conn = if ($null -eq $接続) { '不明' } elseif ($接続) { 'はい' } else { 'いいえ' }
    Write-Host ('POLL 経路={0} 接続={1} 現在={2} 目標={3} 書いた={4}' -f `
        $経路, $conn, $(if ($null -eq $現在) { '?' } else { $現在 }), $Minutes,
        $(if ($書いた) { 'はい' } else { 'いいえ' }))
}

function Resolve-Channel {
    if ($Channel -ne 'Auto') { return $Channel }
    # GG が動いているときだけ Engine を試す。見つからなければ HID。
    $gg = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like 'SteelSeries*' })
    if ($gg.Count -gt 0 -and (Ensure-Endpoint)) { return 'Engine' }
    return 'Hid'
}

function Poll-Engine {
    param([bool]$ForceNow)

    # GG が起動していないと、ここで行く先が決まらない。
    # 分かりにくい URI のエラーではなく、理由を一行で残す。
    if (-not $script:BaseUrl -and -not (Ensure-Endpoint)) {
        if (Write-State '失敗') {
            Write-Log '状態=失敗 Engine のポートが見つからない。GG を開くか -Channel Hid を使う'
        }
        Report-Poll 'Engine' $null $null $false
        return 1
    }

    $dev = Get-ConnectedDevice
    if ($null -eq $dev) {
        if (Write-State '未接続') { Write-Log '状態=未接続 ドングルを認識していない' }
        Report-Poll 'Engine' $false $null $false
        return 0
    }

    $sig = Get-DeviceSignature -DeviceId $dev.id
    $present = Test-BudsPresent -Signature $sig
    if (-not $present) {
        if (Write-State 'イヤホン未接続') { Write-Log '状態=イヤホン未接続' }
        Report-Poll 'Engine' $false $null $false
        return 0
    }

    $cfg = Get-ActiveConfig -DeviceId $dev.id
    $now = Get-CurrentMinutes -Config $cfg
    if ($null -eq $now) {
        Write-Log "状態=失敗 設定項目 inactivity_timer が見つからない: device=$($dev.id)"
        Report-Poll 'Engine' $true $null $false
        return 1
    }

    if ($DryRun) {
        Write-Log ('状態=試行 自動電源オフ={0} 目標={1}' -f (Format-Minutes $now), $Minutes)
        Report-Poll 'Engine' $true $now $false
        return 0
    }

    if ($now -eq $Minutes -and -not $ForceNow) {
        if (Write-State "設定済み=$Minutes") {
            Write-Log ('状態=済み 自動電源オフ={0}' -f (Format-Minutes $now))
        }
        Report-Poll 'Engine' $true $now $false
        return 0
    }

    Set-CurrentMinutes -Config $cfg -DeviceId $dev.id -Value $Minutes
    Start-Sleep -Milliseconds 800
    $after = Get-CurrentMinutes -Config (Get-ActiveConfig -DeviceId $dev.id)
    if ($after -eq $Minutes) {
        Write-State "設定済み=$Minutes"
        Write-Log ('状態=成功 自動電源オフ={0}' -f (Format-Minutes $after))
        Report-Poll 'Engine' $true $after $true
        return 0
    }

    if (Write-State '失敗') {
        Write-Log ('状態=失敗 書き込み後に値が一致しない: 目標={0} 実際={1}' -f $Minutes, $after)
    }
    Report-Poll 'Engine' $true $after $true
    return 1
}

function Poll-Hid {
    param([bool]$ForceNow)

    $st = Read-HidStatus
    if (-not $st.見つかる) {
        if (Write-State 'ドングル無し') { Write-Log '状態=ドングル無し USB に見えない' }
        Report-Poll 'Hid' $false $null $false
        return 1
    }
    if (-not $st.返事) {
        if (Write-State 'イヤホン未接続') { Write-Log ('状態=イヤホン未接続 ' + $st.状態) }
        Report-Poll 'Hid' $false $null $false
        return 0
    }
    if (-not $st.接続) {
        if (Write-State 'イヤホン未接続') { Write-Log ('状態=イヤホン未接続 状態=' + $st.状態) }
        Report-Poll 'Hid' $false $st.分 $false
        return 0
    }

    if ($DryRun) {
        Write-Log ('状態=試行 自動電源オフ={0} 目標={1} 電池={2}' -f (Format-Minutes $st.分), $Minutes, $st.電池)
        Report-Poll 'Hid' $true $st.分 $false
        return 0
    }

    if ($st.分 -eq $Minutes -and -not $ForceNow) {
        if (Write-State "設定済み=$Minutes") {
            Write-Log ('状態=済み 自動電源オフ={0} 電池={1}' -f (Format-Minutes $st.分), $st.電池)
        }
        Report-Poll 'Hid' $true $st.分 $false
        return 0
    }

    try {
        Write-HidMinutes -Value $Minutes
    } catch {
        if (Write-State '失敗') {
            Write-Log "状態=失敗 HID の書き込み: $($_.Exception.Message)"
        }
        Report-Poll 'Hid' $true $st.分 $false
        return 1
    }

    # 同じプロセスで読み直しても返事は来ない（実測）。
    # 確かめは、もう 1 回の実行で分かる。
    Write-State '書き込み済み'
    Write-Log ('状態=書き込み 自動電源オフ={0}←{1} 電池={2}' -f (Format-Minutes $Minutes), (Format-Minutes $st.分), $st.電池)
    Report-Poll 'Hid' $true $st.分 $true
    return 0
}

function Poll {
    param([bool]$ForceNow)

    $ch = Resolve-Channel
    if ($ch -eq 'Engine') {
        try {
            return Poll-Engine -ForceNow $ForceNow
        } catch {
            if (Write-State '失敗') { Write-Log "状態=失敗 Engine: $($_.Exception.Message)" }
            Report-Poll 'Engine' $null $null $false
            return 1
        }
    }
    try {
        return Poll-Hid -ForceNow $ForceNow
    } catch {
        if (Write-State '失敗') { Write-Log "状態=失敗 HID: $($_.Exception.Message)" }
        Report-Poll 'Hid' $null $null $false
        return 1
    }
}

# ==================================================================
# ここから実行
# ==================================================================

Initialize-Log

# GG の画面に出る候補の一覧。ここに無い値のときだけ教える。
$GgChoices = @(0, 1, 5, 10, 15, 30, 45, 60, 75, 90)
if ($Minutes -notin $GgChoices) {
    Write-Log ('状態=注意 目標={0} 分は GG の画面の候補に無い値' -f $Minutes)
    Write-Warning ('{0} 分は GG の画面の候補に無い値です。画面では選択欄が空で出ますが、本体では効きます。' -f $Minutes)
}

# 点検は読み取り 1 回で終わる。詰まっても終わるように、45 秒で外から終わらせる。
[Gamebud.Hid]::Watchdog(45000)
exit (Poll -ForceNow ([bool]$Force))
