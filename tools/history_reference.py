#!/usr/bin/env python3
"""Reference model of the 履歴記録 (per-second journal) rows, summary CSV and data CSV of the original PC Browser.

This is an independent re-implementation of the rules that were measured on a real card against the CSV files exported by
the original application (docs/history-report.md).  The Swift implementation (HistoryReport.swift) is checked against it by
`HistoryReferenceTests`, which feeds both the same synthetic journal.  No card data is stored in this file.

usage: history_reference.py IMAGE FIRST_SECTOR LAST_SECTOR OUTDIR [FIRST_ROW LAST_ROW]
writes OUTDIR/summary.csv and OUTDIR/data.csv (CP932, LF) and prints the number of rows.
"""
import math
import os
import struct
import sys
import time

RING = 604800                    # one week of one-second records; the area carries four reserved slots behind them
EPOCH_UNIX = 946684800           # 2000-01-01 00:00:00
TOL = 5                          # |clock span - (entries - 1)| above this makes the duration the entry count
TRIGGER_NAMES = [(0x1, '衝撃'), (0x2, '急発進/急ブレーキ'), (0x4, '急ハンドル'), (0x8, '急旋回'), (0x10, 'ワンタッチ')]
TRIGGER_BITS = 0x1F


def trigger_text(byte):
    for mask, text in TRIGGER_NAMES:
        if byte & mask:
            return text
    return ''


def clock_at(buf, o):
    y, mo, d, h, mi, s = buf[o:o + 6]
    y += 2000
    if not (1 <= mo <= 12 and 0 <= h <= 23 and 0 <= mi <= 59 and 0 <= s <= 59 and d >= 1):
        return None
    leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
    if d > [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]:
        return None
    # days from civil
    yy = y - (mo <= 2)
    era = yy // 400
    yoe = yy - era * 400
    doy = (153 * (mo + (-3 if mo > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60 + s - EPOCH_UNIX


def date_text(t):
    g = time.gmtime(t + EPOCH_UNIX)
    return '%04d/%02d/%02d' % (g.tm_year, g.tm_mon, g.tm_mday)


def time_text(t):
    g = time.gmtime(t + EPOCH_UNIX)
    return '%02d:%02d:%02d' % (g.tm_hour, g.tm_min, g.tm_sec)


def compact_text(t):
    g = time.gmtime(t + EPOCH_UNIX)
    return '%04d%02d%02d%02d%02d%02d' % (g.tm_year, g.tm_mon, g.tm_mday, g.tm_hour, g.tm_min, g.tm_sec)


def accel_text(v):
    a = abs(v)
    return ('-' if v < 0 else '') + '%d.%d%d' % (a // 1000, (a // 100) % 10, (a // 10) % 10)


def to_wgs84(raw_lat, raw_lon, alt_mm):
    lat = raw_lat / 600000
    lon = raw_lon / 600000
    if not (abs(lat) <= 90 and abs(lon) <= 180 and (lat != 0 or lon != 0)):
        return None
    a = 6377397.155
    b = 6356078.962818188
    a2 = 6378137.0
    b2 = 6356752.314245179
    phi = math.radians(lat)
    lam = math.radians(lon)
    h = alt_mm * 0.001
    e = (a * a - b * b) / (a * a)
    n = a / math.sqrt(1 - e * math.sin(phi) ** 2)
    x = (n + h) * math.cos(phi) * math.cos(lam) - 147
    y = (n + h) * math.cos(phi) * math.sin(lam) + 506
    z = (n * (1 - e) + h) * math.sin(phi) + 687
    p = math.hypot(x, y)
    e2 = (a2 * a2 - b2 * b2) / (a2 * a2)
    ep2 = (a2 * a2 - b2 * b2) / (b2 * b2)
    t = math.atan2(z * a2, p * b2)
    return (math.degrees(math.atan2(z + ep2 * b2 * math.sin(t) ** 3, p - e2 * a2 * math.cos(t) ** 3)),
            math.degrees(math.atan2(y, x)))


def hubeny(p, q):
    f1 = math.radians(p[0])
    f2 = math.radians(q[0])
    dy = f1 - f2
    dx = math.radians(p[1] - q[1])
    mu = (f1 + f2) / 2
    w = math.sqrt(1 - 0.00669437999019757 * math.sin(mu) ** 2)
    m = 6335439.32729246 / w ** 3
    n = 6378137.0 / w
    return math.hypot(dy * m, dx * n * math.cos(mu))


def build(data):
    n = len(data) // 256
    r = min(n, RING)
    kind = bytearray(r)
    ca = [None] * r
    cb = [None] * r
    for i in range(r):
        m = struct.unpack_from('<I', data, i * 256)[0]
        if m == 0xFFFFE202:
            kind[i] = 2
        elif m == 0xFFFFE201:
            kind[i] = 1
        elif m == 0:
            kind[i] = 0
        else:
            kind[i] = 3
        if kind[i] in (1, 2):
            ca[i] = clock_at(data, i * 256 + 0x0E)
            cb[i] = clock_at(data, i * 256 + 0x1E)
    newest = -1
    best = None
    for i in range(r):
        if kind[i] == 2 and cb[i] is not None and (best is None or cb[i] > best):
            best = cb[i]
            newest = i
    if newest < 0:
        return None
    start = ((newest // 2) + 1) * 2 % r
    jb = r - start
    sk = [kind[(start + p) % r] for p in range(r)]
    runs = []
    p = 0
    while p < r:
        if sk[p] == 2:
            q = p
            while q + 1 < r and sk[q + 1] == 2:
                q += 1
            runs.append([p, q])
            p = q + 1
        else:
            p += 1
    gaps = {}
    for k in range(1, len(runs)):
        lo = runs[k - 1][1] + 1
        hi = runs[k][0] - 1
        gaps[k] = (lo, hi, ''.join(str(sk[x]) for x in range(lo, hi + 1)))
    skip = set()
    first_a = [k for k, g in sorted(gaps.items()) if g[1] < jb]
    if first_a and len(gaps[first_a[0]][2]) <= 3:
        skip.add(first_a[0])
    first_b = [k for k, g in sorted(gaps.items()) if g[0] >= jb]
    if first_b and len(gaps[first_b[0]][2]) <= 3:
        skip.add(first_b[0])
    rows = []
    cur = None
    for k, run in enumerate(runs):
        if k > 0 and k in skip:
            cur['runs'].append(k)
            continue
        if k > 0:
            lo, hi, kinds = gaps[k]
            nz = [x for x in range(lo, hi + 1) if sk[x] in (1, 2)]
            if len(kinds) >= 4 and kinds.count('1') >= 3:
                cur['tail'] = nz[:2]
                rows.append({'marker': True, 'emit': nz[2:], 'runs': []})
            else:
                cur['tail'] = nz
        cur = {'runs': [k], 'tail': [], 'marker': False}
        rows.append(cur)
    if not rows:
        return None
    last_run_end = runs[-1][1]
    rows[-1]['tail'] = [x for x in range(last_run_end + 1, r) if sk[x] in (1, 2)]
    for rw in rows:
        if rw['marker']:
            continue
        p0 = runs[rw['runs'][0]][0]
        e0 = p0 + 1 if p0 == 0 else p0
        pl = runs[rw['runs'][-1]][1]
        rw['emit'] = [x for x in range(e0, pl + 1) if sk[x] in (1, 2)] + rw['tail']
    # a row that would not write a single line is dropped, except the last one (it always carries the closing entry)
    rows = [rw for i, rw in enumerate(rows) if rw['emit'] or i == len(rows) - 1]
    entries = []
    for ri, rw in enumerate(rows):
        for q in rw['emit']:
            entries.append((ri, q))
    entries.append((len(rows) - 1, None))
    return {'r': r, 'start': start, 'kind': kind, 'a': ca, 'b': cb, 'sk': sk, 'rows': rows, 'entries': entries}


def export(data, first_row=None, last_row=None):
    j = build(data)
    if j is None:
        return None
    r, start, sk, rows, entries = j['r'], j['start'], j['sk'], j['rows'], j['entries']
    ca, cb = j['a'], j['b']
    slot = lambda p: (start + p) % r
    count = len(entries)

    def a_of(n):
        q = entries[n][1] if 0 <= n < count else None
        return ca[slot(q)] if q is not None else None

    nrows = len(rows)
    lo = 0 if first_row is None else first_row
    hi = nrows - 1 if last_row is None else last_row
    lines = ['GPS時計日付,GPS時計時刻,本体時計日付,本体時計時刻,速度[km/h],加速度X[G],加速度Y[G],加速度Z[G],緯度,経度,進行方向,GPS測位フラグ,イベント種類,SDカードID,機器ID']
    stats = [dict(n=0, first=None, last=None, speed_sum=0, speed_max=0, fix=False, meters=0.0, prev=None, shock=0, hits=0, others=[0, 0, 0])
             for _ in range(nrows)]
    prev_slot = 0                  # scan position of the previous emitted record (the first row starts from position 0)
    kml_entries = []               # (GPS clock, fix byte, speed in mm/s, heading in 1e-5 degree, WGS84 position) of every entry
    last_g = None
    last_body = None
    prev_shown = None
    for n in range(count):
        ri, q = entries[n]
        d = prev_slot
        o = slot(d) * 256
        flag_byte = data[o + 0x25]
        valid = flag_byte in (2, 3)
        a = ca[slot(q)] if q is not None else None
        if valid:
            if q is None or sk[q] == 1:
                g = last_g + 1 if last_g is not None else a
            elif a is not None and a_of(n - 1) == a and a_of(n + 1) == a and last_g is not None:
                g = last_g + 1
            else:
                g = a
        else:
            g = None
        bd = cb[slot(d)]
        if bd is None:
            body = None if last_body is None else last_body + 1
        elif last_body is None or bd >= last_body:
            body = bd
        else:
            body = last_body + 1
        last_g = g
        last_body = body
        speed_raw = struct.unpack_from('<H', data, o + 0x36)[0]
        speed = speed_raw * 36 // 1000
        ax, ay, az = struct.unpack_from('<hhh', data, o + 0xAC)
        raw_lat = struct.unpack_from('<i', data, o + 0x2E)[0]
        raw_lon = struct.unpack_from('<i', data, o + 0x32)[0]
        alt = struct.unpack_from('<i', data, o + 0x3E)[0]
        pos = to_wgs84(raw_lat, raw_lon, alt)
        heading = struct.unpack_from('<I', data, o + 0x3A)[0]
        trig = data[o + 0xA6]
        dev = bytes(data[o + 0x9A:o + 0x9A + 10])
        dev_text = dev.decode('ascii') if all(0x30 <= c <= 0x39 or 0x41 <= c <= 0x5A for c in dev) else ''
        kml_entries.append((g, flag_byte, speed_raw, heading, pos))
        shown = g if g is not None else body
        if shown is None:
            # neither clock is usable: the record's own clock minus one second, else one second after the previous row entry
            own = None
            if q is not None:
                own = cb[slot(q)] if cb[slot(q)] is not None else ca[slot(q)]
            shown = own - 1 if own is not None else (prev_shown + 1 if prev_shown is not None else 0)
        prev_shown = shown
        st = stats[ri]
        st['n'] += 1
        if st['first'] is None:
            st['first'] = shown
        st['last'] = shown
        st['speed_sum'] += speed
        st['speed_max'] = max(st['speed_max'], speed)
        if valid:
            st['fix'] = True
        if flag_byte == 3 and pos is not None:
            if st['prev'] is not None and st['prev'] != pos:
                st['meters'] += hubeny(st['prev'], pos)
            st['prev'] = pos
        if trig & 1:
            st['shock'] += 1
        if trig & 0x2:
            st['others'][0] += 1
        if trig & 0x4:
            st['others'][1] += 1
        if trig & 0x10:
            st['others'][2] += 1
        if trig & TRIGGER_BITS:
            st['hits'] += 1
        if lo <= ri <= hi:
            lat, lon = ('0.000000', '0.000000') if pos is None else ('%.6f' % pos[0], '%.6f' % pos[1])
            gd, gt = (date_text(g), time_text(g)) if g is not None else ('0000/00/00', '00:00:00')
            bdt, bt = (date_text(body), time_text(body)) if body is not None else ('0000/00/00', '00:00:00')
            flag_text = '3D測位' if flag_byte == 3 else '2D測位' if flag_byte == 2 else '非測位'
            lines.append(','.join([gd, gt, bdt, bt, str(speed), accel_text(ax), accel_text(ay), accel_text(az), lat, lon,
                                   '%.1f' % (heading * 1e-5), flag_text, trigger_text(trig), '', dev_text]))
        if q is not None:
            prev_slot = q
    summary = ['日付,時刻,運転時間,走行距離[km],平均速度[km/h],最高速度[km/h],衝撃,急発進/急ブレーキ,急ハンドル,ワンタッチ,回数']
    total_s = 0
    total_m = 0.0
    totals = [0, 0, 0, 0, 0]
    for ri in range(lo, hi + 1):
        st = stats[ri]
        span = st['last'] - st['first']
        dur = span if abs(span - (st['n'] - 1)) <= TOL else st['n']
        dur = max(dur, 1)
        total_s += dur
        total_m += st['meters']
        cells = [date_text(st['first']), time_text(st['first']) + '～' + time_text(st['last']),
                 '%02d:%02d:%02d' % (dur // 3600, dur // 60 % 60, dur % 60)]
        if st['fix']:
            cells += ['%.3f' % (st['meters'] / 1000), '%.1f' % (st['speed_sum'] / st['n']), str(st['speed_max'])]
        else:
            cells += ['', '', '']
        counts = [st['shock']] + st['others'] + [st['hits']]
        for i, c in enumerate(counts):
            totals[i] += c
        cells += [str(c) for c in counts]
        summary.append(','.join(cells) + ',')
    summary.append('合計,,%02d:%02d:%02d,%.3f,,,' % (total_s // 3600, total_s // 60 % 60, total_s % 60, total_m / 1000) +
                   ','.join(str(c) for c in totals) + ',')
    first_start = stats[lo]['first']
    last_end = stats[hi]['last']
    name = '%s_%s_履歴記録レポート' % (compact_text(first_start), compact_text(last_end))
    return {'summary': '\n'.join(summary) + '\n', 'data': '\n'.join(lines) + '\n', 'name': name, 'rows': nrows, 'stats': stats,
            'kml_entries': kml_entries, 'first_clock': stats[0]['first']}


def main(argv):
    image, first, last, out = argv[1], int(argv[2]), int(argv[3]), argv[4]
    with open(image, 'rb') as f:
        f.seek(first * 512)
        data = f.read((last - first + 1) * 512)
    lo = int(argv[5]) if len(argv) > 5 else None
    hi = int(argv[6]) if len(argv) > 6 else None
    res = export(data, lo, hi)
    if res is None:
        print('no journal')
        return 1
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'summary.csv'), 'wb') as f:
        f.write(res['summary'].encode('cp932'))
    with open(os.path.join(out, 'data.csv'), 'wb') as f:
        f.write(res['data'].encode('cp932'))
    with open(os.path.join(out, 'name.txt'), 'w') as f:
        f.write(res['name'])
    print('rows', res['rows'])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
