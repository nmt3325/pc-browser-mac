#!/usr/bin/env python3
"""Reference model of the Google Earth file ("ログデータ変換", GPSログ／Earth) that the original PC Browser writes for the
履歴記録 (per-second journal) list.  An independent re-implementation of the rules measured against the original's own export
(docs/kml-export.md).  The Swift writer (JournalKML.swift) is checked against it by `KMLReferenceTests`, which feeds both the same
synthetic journal.  No card data is stored in this file.

An entry is (clock, fix, speed_raw, heading_raw, position) with clock = seconds since 2000-01-01 of the GPS clock (None without
one), fix = the journal's fix byte (2 or 3 = fix), speed_raw in mm/s, heading_raw in 1e-5 degree and position = (lat, lon) in WGS84
or None (invalid raw coordinate).  The entries and the first clock come from history_reference.export().

usage: kml_reference.py IMAGE FIRST_SECTOR LAST_SECTOR OUT.kml [--density N] [--no-points] [--no-route] [--width N] [--alpha N]
                        [--rgb RRGGBB]
writes the file exactly as the original does (UTF-8 with BOM, CRLF line ends) and prints its default file name.
"""
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import history_reference  # noqa: E402

EPOCH = history_reference.EPOCH_UNIX
WEEKDAYS = '月火水木金土日'


def civil(clock):
    return datetime.datetime.fromtimestamp(EPOCH + clock, datetime.timezone.utc)


def weekday(clock):
    return WEEKDAYS[civil(clock).weekday()]


def colour(alpha, rgb):
    """KML colour AABBGGRR from the 0-255 transparency and the colour button's 0xRRGGBB."""
    r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
    return '%02X%02X%02X%02X' % (alpha, b, g, r)


def coordinate(pos):
    return '%.12f,%.12f,0' % (pos[1], pos[0])


def heading(raw):
    # the original multiplies by 1e-5 and rounds with the FPU's default mode (to nearest, ties to even)
    return int(round(raw * 1e-5))


def default_name(start_clock):
    t = civil(start_clock)
    return 'YP_%04d%02d%02d_%02d%02d%02d' % (t.year, t.month, t.day, t.hour, t.minute, t.second)


def document(entries, start_clock, density=10, points=True, route=True, width=5, alpha=100, rgb=0):
    out = ['\ufeff<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://earth.google.com/kml/2.1">']
    d = civil(start_clock)
    out.append('<Document><name>%04d年 %02d月 %02d日(%s)</name>' % (d.year, d.month, d.day, weekday(start_clock)))
    out.append('<Style id="line_style">')
    out.append('<LineStyle><color>%s</color><width>%d</width></LineStyle></Style>' % (colour(alpha, rgb), width))
    if points:
        out.append('<Folder><name>ポイント</name>')
        for n, (clock, fix, speed_raw, heading_raw, pos) in enumerate(entries):
            if fix not in (2, 3) or n % density != 0 or clock is None:
                continue
            t = civil(clock)
            lat_lon = coordinate(pos) if pos is not None else '0.000000000000,0.000000000000,0'
            h = heading(heading_raw)
            out.append('<Placemark><name>%02d:%02d:%02d</name>' % (t.hour, t.minute, t.second))
            out.append('<Style><IconStyle><color>FF00FF00</color><scale>0.8</scale><Icon><href>http://map.yupiteru-itymap.com/icon/arrow_r_2.png</href></Icon><heading>%d</heading></IconStyle></Style>' % h)
            out.append('<Point><coordinates>%s</coordinates></Point>' % lat_lon)
            out.append('<description><![CDATA[<table><tr><td>日付</td><td>%04d年%02d月%02d日(%s)</td></tr><tr><td>時刻</td><td>%02d時%02d分%02d秒</td></tr>'
                       '<tr><td>速度(GPS値)</td><td>%.1fkm/h</td></tr><tr><td>進行方向</td><td>%.1f度</td></tr></table>]]></description>'
                       % (t.year, t.month, t.day, weekday(clock), t.hour, t.minute, t.second, speed_raw * 0.036, heading_raw * 1e-5))
            lon, lat = lat_lon.split(',')[0:2]
            out.append('<LookAt><longitude>%s</longitude><latitude>%s</latitude><tilt>50</tilt><range>400</range><heading>%d</heading></LookAt>' % (lon, lat, h))
            out.append('</Placemark>')
        out.append('</Folder>')
    if route:
        t = civil(start_clock)
        out.append('<Folder><name>ルート</name>')
        out.append('<Placemark><name>%04d年%02d月%02d日 %02d時%02d分%02d秒</name>' % (t.year, t.month, t.day, t.hour, t.minute, t.second))
        out.append('<styleUrl>#line_style</styleUrl>')
        out.append('<LineString id="CarRoute"><tessellate>1</tessellate>')
        coords = ''.join(coordinate(e[4]) + ' ' for e in entries if e[1] in (2, 3) and e[4] is not None)
        out.append('<coordinates>' + coords)
        out.append('</coordinates></LineString>')
        out.append('</Placemark>')
        out.append('</Folder>')
    out.append('</Document>')
    out.append('</kml>')
    return '\r\n'.join(out) + '\r\n'


def main(argv):
    args = argv[1:]
    options = {'density': 10, 'points': True, 'route': True, 'width': 5, 'alpha': 100, 'rgb': 0}
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '--no-points':
            options['points'] = False
        elif a == '--no-route':
            options['route'] = False
        elif a in ('--density', '--width', '--alpha'):
            i += 1
            options[a[2:]] = int(args[i])
        elif a == '--rgb':
            i += 1
            options['rgb'] = int(args[i], 16)
        else:
            positional.append(a)
        i += 1
    image, first, last, out = positional[0], int(positional[1]), int(positional[2]), positional[3]
    with open(image, 'rb') as f:
        f.seek(first * 512)
        data = f.read((last - first + 1) * 512)
    res = history_reference.export(data)
    if res is None:
        print('no journal')
        return 1
    text = document(res['kml_entries'], res['first_clock'], **options)
    with open(out, 'wb') as f:
        f.write(text.encode('utf-8'))
    print(default_name(res['first_clock']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
