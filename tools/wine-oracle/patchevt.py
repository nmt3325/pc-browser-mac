#!/usr/bin/env python3
"""Patch single sectors of a *copy* of a card image for Wine-oracle experiments, with an undo journal.

  ORACLE_IMG=<working copy of the card image>  ORACLE_EVENT_STARTS='[first D103 sector of each event, ...]'
  patchevt.py apply '<spec json>'     restore the previous patches first, then apply the spec
  patchevt.py restore                 undo every patch recorded in the journal

Spec keys (all offsets are decimal byte offsets inside a 512-byte sector, data is hex):
  "abs": [[sector, offset, hex], ...]                    absolute sector patches
  "pk":  [[H sector, offset, hexForH, hexForT], ...]     patch a D101 header H and its D102 mirror T (T = LE32 at 0x1b4 of H);
                                                         an empty string skips that copy
  "<event index>": {"all"|"first"|"blk": [[offset, hex], ...], "seq": [[lo, hi, offset, base], ...]}
      all   = every packet header and mirror of the event, first = first packet of each block,
      blk   = the D103/D105 block header pair, seq = write a running byte (base + index) into packets lo..hi
Never run this on the original image. Findings are summarised in docs/validation-history.md."""
import json, os, struct, sys

IMG = os.environ['ORACLE_IMG']
BK = os.environ.get('ORACLE_JOURNAL', '/tmp/inv/evt_backup.json')
EVENTS = json.loads(os.environ.get('ORACLE_EVENT_STARTS', '[]'))


def walk(f, start):
    def rd(s):
        f.seek(s * 512)
        return f.read(512)

    def mg(h):
        return struct.unpack_from('<I', h, 0)[0]
    secs = []; sec = start; firsts = []; d103 = 0; blkh = []
    while True:
        m0 = mg(rd(sec))
        if m0 == 0xFFFFD103:
            d103 += 1
            if d103 > 3:
                break
        if m0 in (0xFFFFD103, 0xFFFFD105):
            blkh.append(sec); blkh.append(sec + 1); sec += 2
        first = True
        while True:
            h = rd(sec)
            if mg(h) != 0xFFFFD101:
                break
            tl = struct.unpack_from('<I', h, 0x1b4)[0]
            secs.append(sec); secs.append(tl)
            if first:
                firsts.append(sec); firsts.append(tl); first = False
            sec = tl + 1
        if mg(rd(sec)) in (0xFFFFD106, 0xFFFFD104):
            sec += 2
            if mg(rd(sec)) in (0xFFFFD105, 0xFFFFD103):
                continue
        break
    return secs, firsts, blkh


def restore():
    if not os.path.exists(BK):
        print('nothing to restore'); return
    b = json.load(open(BK)); f = open(IMG, 'r+b')
    for k, v in b.items():
        s, o = k.split(':'); f.seek(int(s) * 512 + int(o)); f.write(bytes.fromhex(v))
    f.close(); os.remove(BK); print('restored', len(b))


def apply(spec):
    restore()
    f = open(IMG, 'r+b'); bk = {}; cnt = 0

    def put(sector, offset, data):
        nonlocal cnt
        key = '%d:%d' % (sector, offset)
        if key not in bk:
            f.seek(sector * 512 + offset); bk[key] = f.read(len(data)).hex()
        f.seek(sector * 512 + offset); f.write(data); cnt += 1
    for s_, off_, hx_ in spec.pop('abs', []):
        put(s_, off_, bytes.fromhex(hx_))
    for h_, off_, hh_, ht_ in spec.pop('pk', []):
        f.seek(h_ * 512 + 0x1b4); t_ = struct.unpack('<I', f.read(4))[0]
        for s_, hx_ in ((h_, hh_), (t_, ht_)):
            if hx_:
                put(s_, off_, bytes.fromhex(hx_))
    for e, rules in spec.items():
        secs, firsts, blkh = walk(f, EVENTS[int(e)])
        print('event', e, 'packets', len(secs), 'blocks', len(firsts))
        for lo, hi, off, base in rules.get('seq', []):
            for i in range(lo, min(hi, len(secs) // 2 - 1) + 1):
                for s in (secs[2 * i], secs[2 * i + 1]):
                    put(s, off, bytes([(base + i - lo) & 255]))
        for kind, targets in (('all', secs), ('first', firsts), ('blk', blkh)):
            for off, hx in rules.get(kind, []):
                for s in targets:
                    put(s, off, bytes.fromhex(hx))
    f.close(); json.dump(bk, open(BK, 'w')); print('patched', cnt)


if __name__ == '__main__':
    if sys.argv[1] == 'restore':
        restore()
    else:
        apply(json.loads(sys.argv[2]))
