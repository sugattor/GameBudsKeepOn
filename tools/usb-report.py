"""USBPcap の pcap を直接読んで、HID の出力報告を並べる。

tshark の項目名が分かりにくいので、ヘッダを自分で読む。
疑似ヘッダは 27 バイトで、次が入っている。

| 位置 | 長さ | 中味 |
|---|---|---|
| 0 | 2 | ヘッダの長さ (27) |
| 2 | 8 | IRP の識別子 |
| 10 | 4 | 状態 |
| 14 | 2 | URB の種類 |
| 16 | 1 | 情報 |
| 17 | 2 | バス番号 |
| 19 | 2 | 機器のアドレス |
| 21 | 1 | 端点 |
| 22 | 1 | 転送の型 |
| 23 | 4 | 本文の長さ |

URB の種類が 0x001b (クラス・インターフェース) で転送の型が 2 (制御) のものは、
本文の先頭 8 バイトが setup で、その後ろに報告の本文が連なる。

使い方:
    python usb-report.py <pcap の道>
"""
import struct
import sys
from collections import Counter
from pathlib import Path

# 採取した pcap の場所は、道具のある場所から出す。tools の 1 つ上の capture\usb
SRC = sys.argv[1] if len(sys.argv) > 1 else str(
    Path(__file__).resolve().parent.parent / "capture" / "usb" / "hub2.pcap")

CLASS_INTERFACE = 0x001B
CONTROL = 0x02
CONTROL_SETUP = 0x08

data = open(SRC, "rb").read()
if data[:4] == b"\xd4\xc3\xb2\xa1":
    e = "<"
elif data[:4] == b"\xa1\xb2\xc3\xd4":
    e = ">"
else:
    raise SystemExit("pcap の魔数が分かりません: %r" % data[:4])

off = 24
base = None
frames = 0
rows = []

while off + 16 <= len(data):
    ts_s, ts_u, cap, _wire = struct.unpack(e + "IIII", data[off:off + 16])
    off += 16
    pkt = data[off:off + cap]
    off += cap
    frames += 1
    if len(pkt) < 27:
        continue
    if base is None:
        base = ts_s + ts_u / 1000000.0
    (_hlen, _irp, _st, func, _info, _bus, dev, ep, xtype, dlen) = struct.unpack(
        e + "HQIHBHHBBI", pkt[0:27])
    # 本文はヘッダの長さの位置から始まる。
    # ヘッダの長さは URB の種類で違う（制御は 28、他は 27 を実測）。
    if _hlen < 27 or _hlen + dlen > len(pkt):
        continue
    body = pkt[_hlen:_hlen + dlen]
    if func not in (CLASS_INTERFACE, CONTROL_SETUP) or xtype != CONTROL:
        continue
    if len(body) < 8:
        continue
    bmt, breq, wval, widx, wlen = struct.unpack("<BBHHH", body[0:8])
    rep = body[8:8 + wlen]
    t = (ts_s + ts_u / 1000000.0) - base
    rows.append((t, func, bmt, breq, wval, widx, wlen, rep, dev, ep))

print("フレーム数: %d   読み取れた制御転送: %d" % (frames, len(rows)))
print("")
print("=== PC から機器へ送った報告（時刻順） ===")
for (t, func, bmt, breq, wval, widx, wlen, rep, dev, ep) in rows:
    if bmt != 0x21:
        continue
    print("  t=%7.3f  アドレス=%d  wIndex=%d  wLen=%d  %s" %
          (t, dev, widx, wlen, rep[:20].hex()))

print("")
print("=== 報告の先頭 2 バイトの数え上げ ===")
c = Counter(r[7][:2].hex() for r in rows if r[2] == 0x21 and len(r[7]) >= 2)
for k, v in c.most_common():
    print("  %s  %d 回" % (k, v))

print("")
print("=== setup の形の数え上げ ===")
c2 = Counter("bmt=0x%02x breq=%d wVal=0x%04x wIdx=%d wLen=%d" %
             (r[2], r[3], r[4], r[5], r[6]) for r in rows)
for k, v in c2.most_common():
    print("  %-52s %3d 回" % (k, v))
