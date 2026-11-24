<#
.SYNOPSIS
    Arctis GameBuds の自動電源オフを、決め値にそろえる。

.DESCRIPTION
    接続を確認し、目標の値を書く。接続できていなければ書かない。
    GG が動いていれば GG 経由、無ければ USB の HID へ直接書く。
    使い方と仕組みは README.md、実測の記録は docs/memo.md。

.PARAMETER Minutes
    自動電源オフの分数。0 はなし。既定は 0。

.PARAMETER Channel
    経路。Auto、Engine、Hid の 3 つ。既定は Auto。

.PARAMETER DryRun
    読むだけで書き込まない。

.EXAMPLE
    .\GameBudsKeepOn.ps1 -DryRun
    .\GameBudsKeepOn.ps1 -Minutes 30
    .\GameBudsKeepOn.ps1 -Channel Hid -Minutes 30
#>

[CmdletBinding()]
param(
    # GG の画面に出る候補は 10 個だけ。
    # それでも本体は候補に無い値をそのまま受ける。3 分を入れて 181 秒で切れた。
    # だから広く通し、GG の候補に無い値のときだけ警告を出す。
    # 上限は 255。HID は分数を 1 バイトで送るので、それ以上は本体に載らない。
    [ValidateRange(0, 255)]
    [int]$Minutes = 0,
    [string]$BaseUrl = '',
    [ValidateSet('Auto', 'Engine', 'Hid')]
    [string]$Channel = 'Auto',
    [switch]$DryRun,
    # 内部用。新プロセスから状態を 1 回読む呼び出し。
    [switch]$ProbeStatus
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest は進捗バーの描画が遅い(5.1 で顕著)。消す。
$ProgressPreference = 'SilentlyContinue'

$script:IsCore = ($PSVersionTable.PSEdition -eq 'Core')
if (-not $script:IsCore) {
    # 5.1 には Invoke-WebRequest の -SkipCertificateCheck が無い。
    # TLS 1.2 を通す。
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # 5.1 は PUT と POST の本文を送る前に Expect: 100-continue を出す。切る。
    [Net.ServicePointManager]::Expect100Continue = $false
    # 5.1 で自己署名の証明書を許す。
    # ScriptBlock 版の ServerCertificateValidationCallback は、
    # .NET のスレッドから呼ばれたときに実行空間が無く失敗する(実測)。
    # 5.1 で動く ICertificatePolicy を使う。
    if (-not ('Gamebud.TrustAllCert' -as [type])) {
        Add-Type -TypeDefinition @'
namespace Gamebud {
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCert : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                                      WebRequest req, int problem) {
        return true;
    }
}
}
'@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object Gamebud.TrustAllCert
}

# Engine の API のポートは、再起動のたびに変わる。実測で確かめた。
# 2026-11-22 の朝は 64255、同じ日の再起動後は 60845 だった。
# だからポートを決め打ちせず、実行のたびに探す。
$script:BaseUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $null } else { $BaseUrl }

$DeviceName = 'arctis_gamebuds_dongle'

# HID の機器の識別。ドングルは 3 つのチャネルを出す。
# 命令を受け付けるチャネルは mi_03（実測で wIndex=3）。
$HidMatch  = 'vid_1038&pid_230a'
$HidIface  = 'mi_03'
# 受け取りのバッファは一番長いレポートに合わせて取る。
# 64 バイトのバッファだと 512 バイトのレポートで止まる（実測）。
$HidBufLen = 513

# ==================================================================
# 表示の補助
# ==================================================================

# 電池は '左,右' の文字列で受ける。1 番目が左、2 番目が右。
function Format-Battery {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '読めず' }
    $v = $Value -split ','
    return ('左{0}%,右{1}%' -f $v[0], $v[1])
}

# ==================================================================
# 経路 1: SteelSeries GG の Engine API
# ==================================================================

# Engine は自己署名の証明書を出す。検証を捨てる。
# 捨て方は版で違う。冒頭の分岐で決める。
function Test-EngineEndpoint {
    param([int]$Port)

    # /v1/connectedDevices が JSON で返るポートが、Engine の API である。
    # 他のポートは 404 か、SSL が通らないので区別できる。実測で確かめた。
    try {
        $u = ("https://127.0.0.1:{0}/v1/connectedDevices" -f $Port)
        $opt = @{
            Uri             = $u
            Headers         = @{ Origin = ("https://127.0.0.1:{0}" -f $Port); Accept = 'application/json' }
            TimeoutSec      = 4
            ErrorAction     = 'Stop'
            UseBasicParsing = $true
        }
        if ($script:IsCore) { $opt.SkipCertificateCheck = $true }
        $r = Invoke-WebRequest @opt
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

function Resolve-Endpoint {
    if ($script:BaseUrl) { return $true }
    $u = Find-BaseUrl
    if ($null -eq $u) { return $false }
    $script:BaseUrl = $u
    Write-Verbose ("Engine のポート: {0}" -f $u)
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
        Headers              = @{ Origin = $script:BaseUrl; Accept = 'application/json' }
        TimeoutSec           = 20
        ErrorAction          = 'Stop'
        UseBasicParsing      = $true
    }
    if ($script:IsCore) { $opt.SkipCertificateCheck = $true }
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
            # 次の実行で探し直させる。
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
        Write-Warning "forceDeploy が失敗したが値は入った可能性が高い: HTTP $($r.Status) $($r.Body)"
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

    // 詰まっても必ず終わるようにする。実行は待ったまま残ってはいけない。
    // 実行が予定通り終わったら Stop で止める。止めないと
    // 対話のシェルをシェルごと終わらせる（実測）。
    static ManualResetEvent s_stop = new ManualResetEvent(true);

    public static void Watchdog(int ms) {
        ManualResetEvent stop = new ManualResetEvent(false);
        s_stop = stop;
        Thread t = new Thread(() => {
            if (!stop.WaitOne(ms)) {
                Console.Error.WriteLine("GameBuds(USBドングル)からの返事が" + (ms / 1000) + "秒来ないので中止。ドングルが刺さっているか確認");
                Environment.Exit(3);
            }
        });
        t.IsBackground = true;
        t.Start();
    }

    public static void Stop() {
        s_stop.Set();
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
        # 6番目と7番目は電池。1番目が左、2番目が右(GG の画面と照合済み)。12番目が自動電源オフの分数。
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
# 実行 1 回
# ==================================================================

# 実行結果の 1 行。画面へ出す。
# 変更前は実行時に読み取った自動電源オフ。読めなければ -。
# 変更後は書き換えた後の値。書き換えて無ければ -。
# HID は同じ実行で読み直せない(実測)ので、HID の変更後は送った値。
# 確かめは次の実行の変更前で見える。
# 電池は経路がどちらでも USB 直接の読み取りで取る。読めなければ 読めず。
function Show-Poll {
    param(
        [string]$経路,
        $接続,
        $変更前,
        [bool]$書いた,
        $変更後,
        [string]$電池 = ''
    )
    $conn = if ($null -eq $接続) { '不明' } elseif ($接続) { 'はい' } else { 'いいえ' }
    $pre = if ($null -eq $変更前) { '-' } else { [string]$変更前 }
    $post = if ($書いた -and $null -ne $変更後) { [string]$変更後 } else { '-' }
    $bat = Format-Battery $電池
    Write-Host ('経路={0} 接続={1} 変更前={2} 目標={3} 変更後={4} 電池={5}' -f `
        $経路, $conn, $pre, $Minutes, $post, $bat)
}

# GG との取り合いで返事を逃したときの新プロセス。
# 同じプロセスでのやり直しは効かない(実測)ので、必ず新しいプロセスで 1 回だけ読ませる。
# STATUS 行を受け取って状態の物にする。取れなければ null。
function Read-HidStatusByNewProcess {
    try {
        $ps = (Get-Process -Id $PID).Path
        $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ProbeStatus 2>$null
        $line = @($out | Where-Object { $_ -match '^STATUS ' }) | Select-Object -Last 1
        if (-not $line) { return $null }
        $kv = @{}
        foreach ($m in [regex]::Matches($line.Trim(), '(\w)=([^\s]*)')) {
            $kv[$m.Groups[1].Value] = $m.Groups[2].Value
        }
        return [pscustomobject]@{
            見つかる = ($kv.F -eq '1')
            返事     = ($kv.R -eq '1')
            接続     = if ($kv.C -eq '1') { $true } elseif ($kv.C -eq '0') { $false } else { $null }
            分       = if ($kv.M -match '^\d+$') { [int]$kv.M } else { $null }
            電池     = [string]$kv.B
            状態     = [string]$kv.S
        }
    } catch { return $null }
}

function Resolve-Channel {
    if ($Channel -ne 'Auto') { return $Channel }
    # GG が動いているときだけ Engine を試す。見つからなければ HID。
    $gg = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like 'SteelSeries*' })
    if ($gg.Count -gt 0 -and (Resolve-Endpoint)) { return 'Engine' }
    return 'Hid'
}

function Invoke-PollEngine {
    # GG が起動していないと、ここで行く先が決まらない。
    # 分かりにくい URI のエラーではなく、理由を一行で出す。
    if (-not $script:BaseUrl -and -not (Resolve-Endpoint)) {
        Write-Host '理由=Engine のポートが見つからない。GG を開くか -Channel Hid を使う'
        Show-Poll 'Engine' $null $null $false
        return 1
    }

    $dev = Get-ConnectedDevice
    if ($null -eq $dev) {
        Show-Poll 'Engine' $false $null $false
        return 0
    }

    $sig = Get-DeviceSignature -DeviceId $dev.id
    $present = Test-BudsPresent -Signature $sig
    if (-not $present) {
        Show-Poll 'Engine' $false $null $false
        return 0
    }

    # GG 経由でも電池は HID から読む。HID は GG と共有して開けられる（実測）。
    # ここがこの実行で唯一の読み取りになる。
    # GG がドングルを覗いているとき、返事を GG に先取りされることがある。
    # そのときはこの実行では読めない(プロセス内のやり直しは効かない・実測)ので、
    # 新プロセスで 1 回だけ読み直す。
    $bat = ''
    try {
        $hs = Read-HidStatus
        if ($hs.返事) { $bat = $hs.電池 }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($bat)) {
        $hs2 = Read-HidStatusByNewProcess
        if ($hs2 -and $hs2.返事) { $bat = $hs2.電池 }
    }

    $cfg = Get-ActiveConfig -DeviceId $dev.id
    $now = Get-CurrentMinutes -Config $cfg
    if ($null -eq $now) {
        Write-Host ('理由=inactivity_timer の設定項目が見つからない: device={0}' -f $dev.id)
        Show-Poll 'Engine' $true $null $false -電池 $bat
        return 1
    }

    if ($DryRun) {
        Show-Poll 'Engine' $true $now $false -電池 $bat
        return 0
    }

    # 現在と同じ値でも毎回書く。
    Set-CurrentMinutes -Config $cfg -DeviceId $dev.id -Value $Minutes
    Start-Sleep -Milliseconds 800
    $after = Get-CurrentMinutes -Config (Get-ActiveConfig -DeviceId $dev.id)
    if ($after -eq $Minutes) {
        Show-Poll 'Engine' $true $now $true -変更後 $after -電池 $bat
        return 0
    }

    Write-Host ('理由=書き込み後に値が一致しない: 目標={0} 実際={1}' -f $Minutes, $after)
    Show-Poll 'Engine' $true $now $true -変更後 $after -電池 $bat
    return 1
}

function Invoke-PollHid {
    $st = Read-HidStatus
    # GG が起動していると返事を先取りされることがある。
    # 機器が見えているのに返事が無いときだけ、新プロセスで 1 回読み直す。
    if ($st.見つかる -and -not $st.返事) {
        $st2 = Read-HidStatusByNewProcess
        if ($st2 -and $st2.返事) { $st = $st2 }
    }
    if (-not $st.見つかる) {
        Write-Host '理由=ドングルが USB に見えない。刺し直す'
        Show-Poll 'Hid' $false $null $false
        return 1
    }
    if (-not $st.返事) {
        Show-Poll 'Hid' $false $null $false
        return 0
    }
    if (-not $st.接続) {
        Show-Poll 'Hid' $false $st.分 $false -電池 $st.電池
        return 0
    }

    if ($DryRun) {
        Show-Poll 'Hid' $true $st.分 $false -電池 $st.電池
        return 0
    }

    # 現在と同じ値でも毎回書く。
    try {
        Write-HidMinutes -Value $Minutes
    } catch {
        Write-Host "理由=HID の書き込みが失敗: $($_.Exception.Message)"
        Show-Poll 'Hid' $true $st.分 $false -電池 $st.電池
        return 1
    }

    # 同じプロセスで読み直しても返事は来ない（実測）。
    # 確かめは、もう 1 回の実行で分かる。
    # 変更後は送った値を出す。
    Show-Poll 'Hid' $true $st.分 $true -変更後 $Minutes -電池 $st.電池
    return 0
}

function Invoke-Poll {
    $ch = Resolve-Channel
    if ($ch -eq 'Engine') {
        try {
            return Invoke-PollEngine
        } catch {
            Write-Host "理由=Engine の実行でエラー: $($_.Exception.Message)"
            Show-Poll 'Engine' $null $null $false
            return 1
        }
    }
    try {
        return Invoke-PollHid
    } catch {
        Write-Host "理由=HID の実行でエラー: $($_.Exception.Message)"
        Show-Poll 'Hid' $null $null $false
        return 1
    }
}

# ==================================================================
# ここから実行
# ==================================================================

# -ProbeStatus は新プロセスからの呼ばれ方。状態を 1 行出して終わる。
if ($ProbeStatus) {
    $st = Read-HidStatus
    $c = if ($null -eq $st.接続) { '?' } elseif ($st.接続) { '1' } else { '0' }
    $m = if ($null -eq $st.分) { '?' } else { [string]$st.分 }
    Write-Output ('STATUS F={0} R={1} C={2} M={3} B={4} S={5}' -f `
        [int]$st.見つかる, [int]$st.返事, $c, $m, $st.電池, $st.状態)
    exit 0
}

# GG の画面に出る候補の一覧。ここに無い値のときだけ教える。
$GgChoices = @(0, 1, 5, 10, 15, 30, 45, 60, 75, 90)
if ($Minutes -notin $GgChoices) {
    Write-Warning ('{0} 分は GG の画面の候補に無い値です。画面では選択欄が空で出ますが、本体では効きます。' -f $Minutes)
}

# 実行は読み取り 1 回で終わる。詰まっても終わるように、45 秒で外から終わらせる。
# 実行が終わったらウォッチドッグを止める。止めると対話のシェルはそのまま残る。
[Gamebud.Hid]::Watchdog(45000)
$code = Invoke-Poll
[Gamebud.Hid]::Stop()

# 結果を表示したあと、毎回キー待ちする。
# 右クリック・ショートカット・.bat 経由では窓が一瞬で閉じて結果が見えない。
# 端末からの実行でも同じで、終了後に画面が残る。
# -ProbeStatus の子プロセスはこの上で終わるので、読み取りのたびに
# ハングすることはない。
# ウォッチドッグは止めた後に待つ。キー待ちのせいで終了を待たされない。
# 入力がリダイレクトされた実行では ReadKey が失敗するので、
# try/catch でつかんで待たずに終わる。
Write-Host ''
Write-Host '続行するには何かキーを押してください . . .'
try { [Console]::ReadKey($true) | Out-Null } catch { }

exit $code
