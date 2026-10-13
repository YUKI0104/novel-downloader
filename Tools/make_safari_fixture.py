#!/usr/bin/env python3
"""生成 Safari binarycookies 测试夹具（M3-d 自检用），并按同一份规格独立复解一遍。

格式（文件头大端 / 页内小端）：
  文件 = "cook" + pageCount(uint32 BE) + pageSizes[](uint32 BE) + pages[]
  page = 0x00000100(uint32 LE) + cookieCount(uint32 LE) + records[]
  record = size,unknown,flags,has_port,domain_off,name_off,path_off,value_off (uint32 LE)
           + expiry(double LE, Mac 2001 epoch) + creation(double LE) + comment_off(uint32 LE)
           + domain\\0 name\\0 path\\0 value\\0
"""
import struct
import sys
import os
from datetime import datetime

MAC_EPOCH = datetime(2001, 1, 1)


def mac_time(day):
    if not day:
        return 0.0
    return (datetime.strptime(day, "%Y-%m-%d") - MAC_EPOCH).total_seconds()


def record(domain, name, value, expiry):
    dom = domain.encode() + b"\0"
    nm = name.encode() + b"\0"
    path = b"/\0"
    val = value.encode() + b"\0"
    base = 52
    do = base
    no = do + len(dom)
    po = no + len(nm)
    vo = po + len(path)
    rec = (struct.pack("<iiiiiiii", 0, 0, 0, 0, do, no, po, vo)
           + struct.pack("<d", expiry) + struct.pack("<d", 0.0) + struct.pack("<i", 0)
           + dom + nm + path + val)
    return struct.pack("<i", len(rec)) + rec[4:]


def page(records):
    return struct.pack("<ii", 0x00000100, len(records)) + b"".join(records)


def write(path, pages):
    data = b"cook" + struct.pack(">i", len(pages)) + b"".join(struct.pack(">i", len(p)) for p in pages) + b"".join(pages)
    with open(path, "wb") as f:
        f.write(data)


def reference_parse(path):
    data = open(path, "rb").read()
    assert data[:4] == b"cook"
    pages = struct.unpack(">i", data[4:8])[0]
    sizes = [struct.unpack(">i", data[8 + 4 * i:12 + 4 * i])[0] for i in range(pages)]
    off = 8 + 4 * pages
    cookies = []
    for size in sizes:
        pg = data[off:off + size]
        off += size
        n = struct.unpack("<i", pg[4:8])[0]
        p = 8
        for _ in range(n):
            rec_size = struct.unpack("<i", pg[p:p + 4])[0]
            rec = pg[p:p + rec_size]
            p += rec_size
            do, no, po, vo = struct.unpack("<iiii", rec[16:32])
            expiry = struct.unpack("<d", rec[32:40])[0]

            def s(o):
                if not o:
                    return ""
                e = rec.index(b"\0", o)
                return rec[o:e].decode("utf-8", "replace")
            cookies.append((s(do), s(no), s(vo), expiry))
    return pages, cookies


def mask(host):
    return host[:2] + "***" + host[-8:] if len(host) > 12 else host[:2] + "***"


def main(outdir):
    os.makedirs(outdir, exist_ok=True)

    other = os.path.join(outdir, "other.binarycookies")
    write(other, [
        page([record(".example.com", "sid", "AAA", mac_time("2027-01-01")),
              record(".apple.com", "lang", "zh-cn", 0.0)]),
        page([record(".github.com", "logged_in", "yes", mac_time("2026-10-11"))]),
    ])

    hit = os.path.join(outdir, "shortdramas.binarycookies")
    write(hit, [
        page([record(".example.com", "sid", "AAA", 0.0),
              record(".shortdramas.com", "sessionid", "SAFARITEST1234567890", mac_time("2027-06-30"))]),
    ])

    expired = os.path.join(outdir, "expired.binarycookies")
    write(expired, [
        page([record(".shortdramas.com", "sessionid", "OLDEXPIRED", mac_time("2020-01-01"))]),
    ])

    for path in (other, hit, expired):
        pages, cookies = reference_parse(path)
        hosts = sorted(set(c[0] for c in cookies))
        sd = [c for c in cookies if "shortdramas.com" in c[0] and c[1] == "sessionid"]
        print(f"[python] {os.path.basename(path)}: pages={pages} cookies={len(cookies)} "
              f"hosts={[mask(h) for h in hosts[:4]]} shortdrama_session={len(sd)} "
              f"value={sd[0][2] if sd else '-'} expiry={sd[0][3] if sd else '-'}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/fqm-m3d")
