#!/usr/bin/env python3
"""Summarise the "AT" records of hook.log written by the run_p7 build: for every call of the original's trigger
accumulator (cause bit and class) the four most recent card reads (sector number, magic, phase byte, trigger flags,
cause mask, clock) and the stack-frame bytes. Usage: atl2.py [hook.log]"""
import os, re, sys, time
f = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('ORACLE_DIR', '/tmp/wine-try') + '/hook.log'
print('log age', int(time.time() - os.path.getmtime(f)))
lines = open(f, 'rb').read().split(b'\n')
n = 0
for i, l in enumerate(lines):
    if l.startswith(b'AT '):
        m = re.search(rb'bit=0x0*([0-9a-f]+) cl=0x0*([0-9a-f]+)', l)
        print('AT', n, 'bit', m.group(1).decode(), 'cl', m.group(2).decode()); n += 1
        for j in range(i + 1, i + 7):
            t = lines[j]
            if t.startswith(b'  LR sec='):
                mm = re.match(rb'  LR sec=0x([0-9a-f]+) d: (.*)\| x: (.*)', t)
                sec = int(mm.group(1), 16); d = bytes.fromhex(mm.group(2).decode().replace(' ', ''))
                print('  LR', sec, 'mg', d[:4].hex(), 'b8', d[8], '0x40', d[0x40:0x41].hex(), '0x44', d[0x44:0x45].hex(), '0x4c', d[0x4c:0x4f].hex(), 't', d[0x0a:0x11].hex())
            elif t.startswith(b'  F: '):
                vals = [int(v, 16) for v in t[5:].split()]
                print('  F', ' '.join('%02x' % v if v < 256 else 'xx' for v in vals))
