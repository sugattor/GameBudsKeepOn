#Requires -PSEdition Core
<#
.SYNOPSIS
    ドングルと USB の HID で直接向き合うための探見本。

.DESCRIPTION
    SteelSeries Engine を通さず、HID の報告を送り受けする。
    実測で分かった形:
      書き込み  出力報告 64 バイト。1 番目が命令、2 番目が値。
                自動電源オフの命令は 0xc1、値は分。
      読み取り  0xb0 を送ると、割り込みの報告に現在の値が戻る。
                報告の 12 番目のバイトが分。

    GG が同じ機器を開いていても開けるかを確かめるのが目的の1つ。

.EXAMPLE
    .\hid-dongle.ps1                 # 候補を並べる
    .\hid-dongle.ps1 -Do 状態        # 現在の設定値を読む
    .\hid-dongle.ps1 -Do 書込 -Minutes 45
#>
[CmdletBinding()]
param(
    [ValidateSet('一覧', '状態', '書込', '機能', '入力', '監視')]
    [string]$Do = '一覧',
    [ValidateRange(0, 1440)]
    [int]$Minutes = 0,
    # 機器の並びから引き当てる語
    [string]$Match = '1038',
    [int]$ReadCount = 8,
    [int]$TimeoutMs = 5000,
    # 1 回の読み取りで待つ時間
    [int]$ReadWaitMs = 1500,
    # 監視の長さ
    [int]$Seconds = 40,
    # 画面の出物をここに書き写す。時間切れで終わっても残る。
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'

if ($LogFile) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogFile) -Force | Out-Null
    Set-Content -LiteralPath $LogFile -Value ('開始 ' + (Get-Date -Format 'HH:mm:ss.fff')) -Encoding utf8
}
function Say([string]$m) {
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding utf8
    }
    Write-Host $m
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Gamebud {
public static class Dongle {
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

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(SafeFileHandle h, byte[] buf, int len, out int written, IntPtr ov);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(SafeFileHandle h, byte[] buf, int len, out int read, IntPtr ov);

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

    // 重複読み取り。時間で切れる。同期読み取りは待ったまま返らない（実測）。
    public static byte[] ReadTimeout(SafeFileHandle h, int len, int ms, out int err) {        err = 0;
        byte[] buf = new byte[len];
        System.Threading.ManualResetEvent ev = new System.Threading.ManualResetEvent(false);
        OV ov = new OV();
        ov.Event = ev.SafeWaitHandle.DangerousGetHandle();
        int read = 0;
        bool ok = ReadFile(h, buf, len, out read, ref ov);
        if (!ok) {
            err = Marshal.GetLastWin32Error();
            if (err != 997) {              // 997 = 実行中（_PENDING）。これは正常。
                return null;
            }
            if (!ev.WaitOne(ms)) {
                CancelIoEx(h, IntPtr.Zero);
                err = 258;                 // 258 = 時間切れ（WAIT_TIMEOUT）
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

    // 読み取り常時待たせ。
    // 時間切れのたびに読み取りを取り消すと、次の返物が取り消した側に吸われて
    // 二度と受け取れない（実測）。取り消さずに待ち続けるための器。
    public class Rd {
        SafeFileHandle h;
        byte[] buf;
        OV ov;
        System.Threading.ManualResetEvent ev;
        bool posted = false;

        public Rd(SafeFileHandle handle, int len) {
            h = handle;
            buf = new byte[len];
            ev = new System.Threading.ManualResetEvent(false);
            ov = new OV();
            ov.Event = ev.SafeWaitHandle.DangerousGetHandle();
        }

        public void Post() {
            if (posted) { return; }
            ev.Reset();
            ov = new OV();
            ov.Event = ev.SafeWaitHandle.DangerousGetHandle();
            int read = 0;
            bool ok = ReadFile(h, buf, buf.Length, out read, ref ov);
            posted = true;
            if (ok) {
                // 既に終わった形で返った。次に取り出す。
                ev.Set();
            }
        }

        // ms のあいだ待つ。受け取れたら中身を、無ければ null を返す。
        // 待てなかったら読み取りは待たせたまま残す。
        public byte[] Take(int ms, out int err) {
            err = 0;
            if (!ev.WaitOne(ms)) { err = 258; return null; }
            int read = 0;
            if (!GetOverlappedResult(h, ref ov, out read, false)) {
                err = Marshal.GetLastWin32Error();
                posted = false;
                return null;
            }
            posted = false;
            if (read <= 0) { return null; }
            byte[] got = new byte[read];
            Array.Copy(buf, got, read);
            return got;
        }

        public void Abort() {
            if (posted) { CancelIoEx(h, IntPtr.Zero); posted = false; }
        }

        public bool Pending() { return posted; }
    }

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetOutputReport(SafeFileHandle h, byte[] buf, int len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetFeatureReport(SafeFileHandle h, byte[] buf, int len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetInputReport(SafeFileHandle h, byte[] buf, int len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_FlushQueue(SafeFileHandle h);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetProductString(SafeFileHandle h, byte[] buf, int len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(SafeFileHandle h, byte[] attrs);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr data);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern int HidP_GetCaps(IntPtr data, byte[] caps);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_FreePreparsedData(IntPtr data);

    // 詰まっても必ず終わるようにする。読み取りはデータが無いと止まる。
    public static void Watchdog(int ms) {
        Thread t = new Thread(() => {
            Thread.Sleep(ms);
            Console.Error.WriteLine("時間切れで終えた");
            Environment.Exit(3);
        });
        t.IsBackground = true;
        t.Start();
    }

    public static List<string> Enumerate() {
        List<string> res = new List<string>();
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

    public static string Product(SafeFileHandle h) {
        byte[] b = new byte[256];
        if (!HidD_GetProductString(h, b, b.Length)) { return ""; }
        return System.Text.Encoding.Unicode.GetString(b).TrimEnd('\0');
    }

    public static string Attributes(SafeFileHandle h) {
        byte[] a = new byte[12];
        // Size は 4 バイトの整数。呼び出す前に大きさを置いておく。
        BitConverter.GetBytes(12).CopyTo(a, 0);
        if (!HidD_GetAttributes(h, a)) { return ""; }
        int vid = BitConverter.ToUInt16(a, 4);
        int pid = BitConverter.ToUInt16(a, 6);
        return string.Format("{0:x4}:{1:x4}", vid, pid);
    }

    // 報告の長さ。HIDP_CAPS の決まった位置から読む。
    // 成功の返り値は 0 ではなく 0x110000。
    // 実測で割り込みには 512 バイトの報告が混じる。受け取りのバッファは最大値で取る。
    public static int[] Caps(SafeFileHandle h) {
        IntPtr data;
        if (!HidD_GetPreparsedData(h, out data)) { return new int[] { -1, -1, -1 }; }
        byte[] caps = new byte[40];
        int code = HidP_GetCaps(data, caps);
        HidD_FreePreparsedData(data);
        if (code != 0x00110000) { return new int[] { -code, -1, -1 }; }
        return new int[] {
            BitConverter.ToInt16(caps, 4),   // 報告の最大長
            BitConverter.ToInt16(caps, 6),   // 入力の報告
            BitConverter.ToInt16(caps, 8),   // 出力の報告
            BitConverter.ToInt16(caps, 10),  // 機能の報告
            BitConverter.ToInt16(caps, 0),   // 用途の組
            BitConverter.ToInt16(caps, 2)    // 用途
        };
    }
}
}
'@

function Open-Dongle([string]$Path) {
    # 読み書き両方。他の相手（GG）と共有する。
    # 重複読み取りを使うので FILE_FLAG_OVERLAPPED を付ける。
    $h = [Gamebud.Dongle]::CreateFile($Path, -1073741824, 3, [IntPtr]::Zero, 3, 1073741824, [IntPtr]::Zero)
    if ($null -eq $h -or $h.IsInvalid) {
        Say ('  開けない GetLastError=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        return $null
    }
    return $h
}

function Read-Reports($h, [int]$Len, [int]$Count) {
    # 注意: $got += , @(...) は平らに広がる。報告の区切りが消える。
    # 必ず 1 件ずつ足す物を使う。
    $got = [System.Collections.Generic.List[byte[]]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $err = 0
        $r = [Gamebud.Dongle]::ReadTimeout($h, $Len, $ReadWaitMs, [ref]$err)
        if ($null -eq $r) {
            Say ('  ここから読み取り無し GetLastError=' + $err)
            break
        }
        $got.Add($r)
    }
    # 注意: return $got は一覧をばらばらに展開する。1 件のかたまりのまま返す。
    return ,$got
}

function Write-Report($h, [byte[]]$Body) {
    # 報告番号が 0 の作りでは、先頭に 0 を入れて 1 バイト増やす。
    # HidD_SetOutputReport は渡した長さのまま送信するので、
    # USB 上では実測と同じ 64 バイトの SET_REPORT になる。
    $buf = New-Object byte[] ($Body.Length + 1)
    $buf[0] = 0
    [Array]::Copy($Body, 0, $buf, 1, $Body.Length)
    $ok = [Gamebud.Dongle]::HidD_SetOutputReport($h, $buf, $buf.Length)
    return @{ 成功 = $ok; 書いた = $buf.Length; 失敗 = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
}

# 候補を引き当てる
$paths = [Gamebud.Dongle]::Enumerate() | Where-Object { $_ -like "*$Match*" }
if (-not $paths) {
    Say "見つからない: $Match を含む HID が見つからない"
    exit 1
}

$cands = @()
foreach ($p in $paths) {
    $h = Open-Dongle $p
    if ($null -eq $h) { continue }
    $caps = [Gamebud.Dongle]::Caps($h)
    $cands += [pscustomobject]@{
        道       = $p
        説明     = [Gamebud.Dongle]::Product($h)
        機器     = [Gamebud.Dongle]::Attributes($h)
        報告最大 = $caps[0]
        入力報告 = $caps[1]
        出力報告 = $caps[2]
        機能報告 = $caps[3]
        handle   = $h
    }
}

Say '=== HID の候補 ==='
foreach ($c in $cands) {
    Say ('  報告最大={0,3} 入力={1,3} 出力={2,3} 機能={3,3}  機器={4}  説明={5}' -f `
        $c.報告最大, $c.入力報告, $c.出力報告, $c.機能報告, $c.機器, $c.説明)
    Say ('    ' + $c.道)
}

# 命令のチャネルは mi_03（インターフェース番号 3）。実測で wIndex=3。
$target = $cands |
    Sort-Object { if ($_.道 -like '*mi_03*') { 0 } else { 1 } } |
    Where-Object { $_.出力報告 -ge 65 } |
    Select-Object -First 1
if (-not $target) {
    Say ''
    Say '出力報告 65 以上のものが見つからない。上の表を見て判断する。'
    exit 1
}

# 受け取りのバッファは一番長い報告に合わせて取る。
# 64 バイトのバッファだと 512 バイトの報告で止まる（実測）。
$ReadLen = [Math]::Max(513, [int]$target.入力報告)

Say ''
Say ('使う物: ' + $target.道)
Say ('受け取りのバッファ: ' + $ReadLen + ' バイト')

$limit = $TimeoutMs
if ($Do -eq '監視' -and $limit -lt ($Seconds + 12) * 1000) {
    $limit = ($Seconds + 12) * 1000
}
[Gamebud.Dongle]::Watchdog($limit)

if ($Do -eq '一覧') {
    foreach ($c in $cands) { if ($c.handle -and -not $c.handle.IsInvalid) { $c.handle.Close() } }
    exit 0
}

# 受け取った報告の説明。
# 読み取りのbufは 0 番目が報告番号で、実測の並びは 1 番目から始まる。
function Explain-Report([byte[]]$r) {
    $kind = $r[1]
    $extra = ''
    if ($kind -eq 0xb0 -and $r.Count -ge 13) {
        # 実測: 6番目と7番目は電池、12番目は自動電源オフの分
        $extra = ('  【電池={0}%,{1}% 自動電源オフ={2}分】' -f $r[6], $r[7], $r[12])
    }
    $hex = ($r | ForEach-Object { '{0:x2}' -f $_ }) -join ''
    return ('  報告 0x{0:x2} 受け取り{1}バイト{2}  並び: {3}' -f $kind, $r.Length, $extra,
        $hex.Substring(0, [Math]::Min(48, $hex.Length)))
}

# 決まった間隔で状態を並べる。出し入れの最中に何が変わるか見るため。
if ($Do -eq '監視') {
    # 見つけるときに開けた窓は閉じる。開けっ放しの窓があると
    # 2 回目以降の返事が来ない可能性を見る。
    foreach ($c in $cands) { if ($c.handle -and -not $c.handle.IsInvalid) { $c.handle.Close() } }
    # 窓を開けっ放しにすると受け渡しが壊れる（実測）。読むたびに開け閉じする。
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $h = Open-Dongle $target.道
        if ($null -eq $h) { Say ('  {0}  開けない' -f (Get-Date -Format 'HH:mm:ss')); Start-Sleep -Seconds 2; continue }
        # 状態の回と全く同じ手順にする。
        # 開いた後にキューを流し捨てる、書く、その後に読む。
        [Gamebud.Dongle]::HidD_FlushQueue($h) | Out-Null
        Write-Report $h ([byte[]]@(0xb0, 0x00) + (New-Object byte[] 62)) | Out-Null
        $rd = [Gamebud.Dongle+Rd]::new($h, $ReadLen)
        $rd.Post()
        $err = 0
        $r = $rd.Take($ReadWaitMs, [ref]$err)
        if ($null -ne $r -and $r.Length -ge 13 -and $r[1] -eq 0xb0) {
            Say ('  {0}  状態={1:x2},{2:x2} 電池={3}%,{4}% 自動電源オフ={5}分' -f `
                (Get-Date -Format 'HH:mm:ss'), $r[4], $r[5], $r[6], $r[7], $r[12])
        } else {
            Say ('  {0}  返事が無い 失敗番号={1}' -f (Get-Date -Format 'HH:mm:ss'), $err)
        }
        $rd.Abort()
        $h.Close()
        Start-Sleep -Seconds 2
    }
    exit 0
}

# 状態を読む: 0xb0 を送って、報告の 12 番目のバイトを見る
if ($Do -eq '状態') {
    [Gamebud.Dongle]::HidD_FlushQueue($target.handle) | Out-Null
    $w = Write-Report $target.handle ([byte[]]@(0xb0, 0x00) + (New-Object byte[] 62))
    Say ('命令 0xb0 を送った: 成功={0} 長さ={1} GetLastError={2}' -f $w.成功, $w.書いた, $w.失敗)
    $reports = Read-Reports $target.handle $ReadLen $ReadCount
    Say ('受け取った報告: ' + $reports.Count)
    foreach ($r in $reports) { Say (Explain-Report $r) }
    $target.handle.Close()
    exit 0
}

# 制御転送で読む。割り込みの流れを奪わない。
if ($Do -eq '機能' -or $Do -eq '入力') {
    $feat = ($Do -eq '機能')
    $len = if ($feat) { 515 } else { 65 }
    $buf = New-Object byte[] $len
    $buf[0] = 0
    $ok = if ($feat) {
        [Gamebud.Dongle]::HidD_GetFeatureReport($target.handle, $buf, $len)
    } else {
        [Gamebud.Dongle]::HidD_GetInputReport($target.handle, $buf, $len)
    }
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Say ('制御の読み出し 成功={0} GetLastError={1}' -f $ok, $err)
    if ($ok) {
        $hex = ($buf | ForEach-Object { '{0:x2}' -f $_ }) -join ''
        Say ('  先頭 64 バイト: ' + $hex.Substring(0, [Math]::Min(128, $hex.Length)))
        Say ('  非 0 の位置: ' + (($buf | ForEach-Object -Begin { $i = 0 } -Process { if ($_ -ne 0) { $i }; $i++ } | Select-Object -First 40) -join ','))
    }
    $target.handle.Close()
    exit 0
}

# 自動電源オフを書く: 0xc1 と分
if ($Do -eq '書込') {
    $body = [byte[]]@(0xc1, [byte]$Minutes) + (New-Object byte[] 62)
    $w = Write-Report $target.handle $body
    Say ('命令 0xc1 値={0} を送った: 成功={1} 長さ={2} GetLastError={3}' -f $Minutes, $w.成功, $w.書いた, $w.失敗)
    $reports = Read-Reports $target.handle $ReadLen $ReadCount
    foreach ($r in $reports) { Say (Explain-Report $r) }
    $target.handle.Close()
    exit 0
}





