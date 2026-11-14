#!/usr/bin/env python3
"""Synthetic recording-settings card image and independent checks of --settings-show / --settings-apply (generic bytes only).

The image is built here from scratch (nothing from a real card): MBR, a FAT16 partition with a CONFIG folder, the control and channel
sectors in the layout that was established from the original application, and their backups directly behind the last journal sector.
The checks re-implement the checksum, the region table and a FAT16 reader independently of the Swift code. The image is a sparse file
of about 179 MB (a real 168 h history needs that much), so every check reads only the sectors it needs.
Section 9 covers 録画データ削除 / 記録設定データ初期化 (`--erase-recordings`): the generation byte and region counters change in exactly the
modelled bytes of a NEW copy, nothing else moves, and the catalog then skips the regions the generation rule hides (all generation values
here are made up).
"""
import hashlib
import json
import shutil
import struct
import subprocess
from pathlib import Path

MARKER = b'YP_FORMAT_1.01__\0'
JOURNAL_END = 350_000
TOTAL_SECTORS = JOURNAL_END + 10
PARTITION_SECTORS = 4137
CONTROL = 1 + PARTITION_SECTORS
CHANNEL = CONTROL + 1
FIRST_RECORD = CONTROL + 4
BACKUP_CHANNEL = JOURNAL_END + 1
BACKUP_CONTROL = JOURNAL_END + 2
HISTORY_SECTORS = 168 * 1800
JOURNAL_START = JOURNAL_END - HISTORY_SECTORS + 1
NORMAL_END = JOURNAL_START * 71 // 1200 * 12
VERSION_TEXT = b'[SYNTHETIC]\r\nKEY=1\r\n'


def word(buf, offset, value):
    struct.pack_into('<I', buf, offset, value)


def half(buf, offset, value):
    struct.pack_into('<H', buf, offset, value)


def seal(control, channel):
    """Stored checksum: 2 x (every control byte except the checksum + every channel byte), modulo 65536."""
    c = bytearray(control)
    total = sum(c) - c[0x12] - c[0x13] + sum(channel)
    half(c, 0x12, (total * 2) & 0xFFFF)
    return bytes(c), bytes(channel)


def factory(first):
    c = bytearray(512)
    c[1:18] = MARKER
    c[0x1EC:0x1FD] = MARKER
    c[0x00], c[0x14], c[0x20] = 1, 1, 2
    first8 = bytes([0x0B, 0x10, 0x27, 0x01, 0x1E, 0x00, 0x00, 0x00])
    event8 = bytes([0x0B, 0x10, 0x27, 0x01, 0x1E, 0x00, 0x84, 0x03])
    c[0x21:0x29], c[0x29:0x31], c[0x31:0x39] = first8, event8, event8
    c[0x3A:0x40] = bytes([2, 2, 2, 1, 3, 1])
    c[0x46], c[0x47], c[0x48], c[0x49], c[0x4A], c[0x50], c[0x51] = 5, 2, 5, 5, 5, 3, 1
    for i, v in enumerate((first, NORMAL_END, NORMAL_END + 1, JOURNAL_START - 1, JOURNAL_START, JOURNAL_END)):
        word(c, 0x1BE + 4 * i, v)
    for i in range(8):
        c[0x1D6 + i] = 0xA1 + i
    c[0x1DC] = 0x14  # model code of the Q-01 family: the family whose password gate is implemented
    word(c, 0x1E0, 1)
    word(c, 0x1E4, 1)
    word(c, 0x1E8, 1)
    c[0x1FF] = 1
    ch = bytearray(512)
    ch[0x14], ch[0x15], ch[0x16] = 1, 1, 1
    ch[0x20:0x39] = c[0x20:0x39]
    return seal(c, ch)


def put83(p, offset, name, attribute, cluster, size):
    p[offset:offset + 11] = name
    p[offset + 11] = attribute
    half(p, offset + 26, cluster)
    word(p, offset + 28, size)


def fat16_partition(sectors, fat_sectors=17):
    p = bytearray(sectors * 512)
    p[0:3] = bytes([0xEB, 0x3C, 0x90])
    p[3:11] = b'MSDOS5.0'
    half(p, 11, 512)
    p[13] = 1
    half(p, 14, 1)
    p[16] = 2
    half(p, 17, 32)
    half(p, 19, sectors)
    p[21] = 0xF8
    half(p, 22, fat_sectors)
    p[510:512] = b'\x55\xaa'
    fat_start, fat_bytes = 512, fat_sectors * 512
    root_start = fat_start + 2 * fat_bytes
    data_start = root_start + 32 * 32
    for copy in range(2):
        base = fat_start + copy * fat_bytes
        for index, value in enumerate((0xFFF8, 0xFFFF, 0xFFFF, 0xFFFF)):
            half(p, base + 2 * index, value)
    put83(p, root_start, b'CONFIG     ', 0x10, 2, 0)
    put83(p, data_start, b'.          ', 0x10, 2, 0)
    put83(p, data_start + 32, b'..         ', 0x10, 0, 0)
    put83(p, data_start + 64, b'VERSION INI', 0x20, 3, len(VERSION_TEXT))
    p[data_start + 512:data_start + 512 + len(VERSION_TEXT)] = VERSION_TEXT
    return bytes(p)


EVENT_START = NORMAL_END + 1


def stream_header(magic, own_sector, stamp, generation):
    """First header of a recording area: stream magic, own sector at 0x1E0, card-generation stamp at 0xA0, ring generation at 0x1F8."""
    b = bytearray(512)
    struct.pack_into('<I', b, 0, magic)
    struct.pack_into('<I', b, 0x1E0, own_sector)
    b[0xA0] = stamp
    struct.pack_into('<I', b, 0x1F8, generation)
    return bytes(b)


def journal_head(lap):
    """First journal record: its magic and the ring lap in the upper half of the dword at 0xC4."""
    b = bytearray(512)
    struct.pack_into('<I', b, 0, 0xFFFFE202)
    struct.pack_into('<I', b, 0xC4, (lap << 16) | 0x0123)
    return bytes(b)


def write_image(path, heads=False):
    """Writes the sparse synthetic card image: only the sectors that carry data are written.
    With `heads` the three recording areas also get a head header (made-up stamp 1 and ring generations 5 / 4 / lap 3)."""
    control, channel = factory(FIRST_RECORD)
    mbr = bytearray(512)
    mbr[0x1BE + 4] = 0x06
    word(mbr, 0x1BE + 8, 1)
    word(mbr, 0x1BE + 12, PARTITION_SECTORS)
    mbr[510:512] = b'\x55\xaa'
    with open(path, 'wb') as f:
        f.truncate(TOTAL_SECTORS * 512)
        f.seek(0)
        f.write(mbr)
        f.seek(512)
        f.write(fat16_partition(PARTITION_SECTORS))
        for n, data in ((CONTROL, control), (CHANNEL, channel), (BACKUP_CHANNEL, channel), (BACKUP_CONTROL, control)):
            f.seek(n * 512)
            f.write(data)
        if heads:
            for n, data in ((FIRST_RECORD, stream_header(0xFFFFD105, FIRST_RECORD, 1, 5)), (EVENT_START, stream_header(0xFFFFD103, EVENT_START, 1, 4)),
                            (JOURNAL_START, journal_head(3))):
                f.seek(n * 512)
                f.write(data)


def read_range(path, start, length):
    with open(path, 'rb') as f:
        f.seek(start)
        return f.read(length)


def sector(path, n):
    return read_range(path, n * 512, 512)


def file_sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def changed_sectors(a, b):
    """Numbers of the sectors that differ between two image files (compared in 1 MiB steps)."""
    assert Path(a).stat().st_size == Path(b).stat().st_size
    result, offset = set(), 0
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        while True:
            x, y = fa.read(1 << 20), fb.read(1 << 20)
            if not x and not y:
                break
            assert len(x) == len(y)
            if x != y:
                result |= {(offset + i) // 512 for i in range(0, len(x), 512) if x[i:i + 512] != y[i:i + 512]}
            offset += len(x)
    return result


def changed_offsets(a, b):
    return {i for i in range(len(a)) if a[i] != b[i]}


def checksum_ok(control, channel):
    return seal(control, channel)[0] == control


class Fat16:
    """Minimal independent FAT16 reader for the generated fixture (512-byte clusters, one cluster per directory)."""

    def __init__(self, disk):
        self.part = disk[512:512 + PARTITION_SECTORS * 512]
        p = self.part
        self.fat_start = struct.unpack_from('<H', p, 14)[0] * 512
        self.fat_bytes = struct.unpack_from('<H', p, 22)[0] * 512
        self.fats = [p[self.fat_start + i * self.fat_bytes:self.fat_start + (i + 1) * self.fat_bytes] for i in range(p[16])]
        self.root_start = self.fat_start + p[16] * self.fat_bytes
        self.root_entries = struct.unpack_from('<H', p, 17)[0]
        self.data_start = self.root_start + self.root_entries * 32

    def entry(self, index, copy=0):
        return struct.unpack_from('<H', self.fats[copy], index * 2)[0]

    def cluster_offset(self, n):
        return self.data_start + (n - 2) * 512

    def listing(self, raw):
        live, deleted = [], []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[11] == 0x0F:
                continue
            item = {'name': bytes(e[:11]), 'attr': e[11], 'cluster': struct.unpack_from('<H', e, 26)[0], 'size': struct.unpack_from('<I', e, 28)[0]}
            (deleted if e[0] == 0xE5 else live).append(item)
        return live, deleted

    def root(self):
        return self.listing(self.part[self.root_start:self.data_start])

    def directory(self, cluster):
        offset = self.cluster_offset(cluster)
        return self.listing(self.part[offset:offset + 512])

    def chain(self, first):
        result, n = [], first
        while 2 <= n < 0xFFF8:
            assert n not in result, 'FAT loop'
            result.append(n)
            n = self.entry(n)
        return result

    def read(self, item):
        data = b''.join(self.part[self.cluster_offset(n):self.cluster_offset(n) + 512] for n in self.chain(item['cluster']))
        return data[:item['size']]


def volume_bytes(path):
    """The MBR and the FAT16 partition of an image file (everything the volume checks need)."""
    return read_range(path, 0, (1 + PARTITION_SECTORS) * 512)


def check_volume(disk):
    """Both FAT copies agree and the allocated clusters are exactly the chains reachable from the directory entries."""
    f = Fat16(disk)
    assert f.fats[0] == f.fats[1], 'FAT copies differ'
    allocated = {i for i in range(2, f.fat_bytes // 2) if f.entry(i) != 0}
    live_root, _ = f.root()
    used = set()
    names = {}
    for item in live_root:
        if item['cluster'] >= 2:
            chain = f.chain(item['cluster'])
            assert not (used & set(chain)), 'cross-linked clusters'
            used |= set(chain)
        if item['name'] == b'CONFIG     ':
            live, deleted = f.directory(item['cluster'])
            names = {e['name']: e for e in live}
            for e in live:
                if e['cluster'] >= 2 and e['name'][:1] != b'.':
                    chain = f.chain(e['cluster'])
                    assert not (used & set(chain)), 'cross-linked clusters'
                    used |= set(chain)
                    assert len(chain) * 512 >= e['size'] > (len(chain) - 1) * 512, ('size/chain mismatch', e)
    assert allocated == used, ('allocated clusters differ from reachable ones', sorted(allocated ^ used))
    return f, names


def cli(binary, *arguments):
    return subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, timeout=120)


def ok(binary, *arguments):
    process = cli(binary, *arguments)
    if process.returncode:
        raise RuntimeError('exit %d: %s' % (process.returncode, (process.stdout + process.stderr)[-1500:]))
    return process


def refused(binary, *arguments):
    process = cli(binary, *arguments)
    assert process.returncode != 0 and process.stderr.strip(), ('expected a refusal', arguments, process.stdout, process.stderr)
    return process


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def erase_checks(binary, root, plain_card, plain_hash):
    """Section 9 of `run`. Expected bytes are computed here from the documented rules, not by the Swift code."""
    out = {}
    card = root / 'erase-card.img'
    write_image(card, heads=True)
    card_hash = file_sha(card)
    card.chmod(0o444)
    control, channel = sector(card, CONTROL), sector(card, CHANNEL)
    assert checksum_ok(control, channel) and control[0] == 1 and control[0x1FF] == 1

    def counters(c):
        return [struct.unpack_from('<I', c, o)[0] for o in (0x1E0, 0x1E4, 0x1E8)]

    # 9a. Plan only: the generation goes 1 -> 2 and each counter lands one above the ring generation that was loaded (5 / 4 / lap 3).
    plan_path = root / 'erase-plan.json'
    ok(binary, '--erase-recordings', card, '--erase-kind', 'delete', '--plan-only', plan_path)
    plan = load(plan_path)
    assert plan['operation'] == 'delete' and plan['dataZeroed'] is False and plan['changesSectors'] is True, plan
    assert plan['before'] == {'generation': 1, 'counters': [1, 1, 1]} and plan['after'] == {'generation': 2, 'counters': [6, 5, 4]}, plan
    assert plan['loadedRegions'] == ['常時録画', 'イベント記録', '履歴記録'] and plan['hiddenBefore'] == [], plan
    assert [p['role'] for p in plan['patches']] == ['control', 'channel', 'controlBackup', 'channelBackup']
    assert [p['changed'] for p in plan['patches']] == [True, False, True, False], plan['patches']
    assert plan['patches'][0]['oldSHA256'] == sha(control) and plan['patches'][1]['oldSHA256'] == sha(channel)
    assert plan['settingsBefore'] == plan['settingsAfter']

    # 9b. Refusals leave no output behind: no confirmation, existing output, the input itself, unknown kind, missing kind / output.
    target = root / 'erase-refused.img'
    refused(binary, '--erase-recordings', card, '--erase-kind', 'delete', '--out', target)
    refused(binary, '--erase-recordings', card, '--erase-kind', 'initialize', '--out', target)
    refused(binary, '--erase-recordings', card, '--erase-kind', 'format', '--out', target, '--confirm-erase')
    refused(binary, '--erase-recordings', card, '--out', target, '--confirm-erase')
    refused(binary, '--erase-recordings', card, '--erase-kind', 'delete', '--confirm-erase')
    assert not target.exists()
    keep = root / 'erase-existing.img'
    keep.write_bytes(b'keep')
    refused(binary, '--erase-recordings', card, '--erase-kind', 'delete', '--out', keep, '--confirm-erase')
    assert keep.read_bytes() == b'keep'
    refused(binary, '--erase-recordings', card, '--erase-kind', 'delete', '--out', card, '--confirm-erase')
    assert file_sha(card) == card_hash, 'the input image must not change'

    # 9c. Delete: only the control sector and its backup change, in exactly the generation byte, its tail copy, the counters and the checksum.
    deleted = root / 'erase-delete.img'
    report = root / 'erase-delete.json'
    ok(binary, '--erase-recordings', card, '--erase-kind', 'delete', '--out', deleted, '--confirm-erase', '--report', report)
    assert deleted.stat().st_size == card.stat().st_size and changed_sectors(card, deleted) == {CONTROL, BACKUP_CONTROL}, changed_sectors(card, deleted)
    want = bytearray(control)
    want[0x00] = want[0x1FF] = 2
    for o, v in ((0x1E0, 6), (0x1E4, 5), (0x1E8, 4)):
        word(want, o, v)
    want_control, _ = seal(bytes(want), channel)
    assert sector(deleted, CONTROL) == want_control and sector(deleted, BACKUP_CONTROL) == want_control
    assert sector(deleted, CHANNEL) == channel and sector(deleted, BACKUP_CHANNEL) == channel
    assert changed_offsets(control, want_control) - {0x12, 0x13} == {0x00, 0x1E0, 0x1E4, 0x1E8, 0x1FF}
    done = load(report)
    assert done['output']['verified'] is True and done['dataZeroed'] is False and done['after']['generation'] == 2, done
    assert plan['patches'][0]['newSHA256'] == sha(want_control)
    for n in (FIRST_RECORD, EVENT_START, JOURNAL_START):
        assert sector(deleted, n) == sector(card, n), 'recorded data must stay where it was'
    assert file_sha(card) == card_hash, 'the input image must not change'
    out['delete'] = {'changed_sectors': 2, 'generation_after': 2}

    # 9d. Readers: the original card lists nothing hidden; the deleted copy hides the three areas. The settings stay readable.
    for name, path in (('before', card), ('after', deleted)):
        shown = root / ('erase-inspect-%s.json' % name)
        ok(binary, '--inspect', path, '--catalog-only', '--scan-limit', 8 * 1024 * 1024, '--report', shown)
        hidden = load(shown)['hidden_regions']
        if name == 'before':
            assert hidden == [], hidden
        else:
            assert len(hidden) == 3 and hidden[0].startswith('常時録画') and hidden[1].startswith('イベント記録') and hidden[2].startswith('履歴記録'), hidden
    show = root / 'erase-show-delete.json'
    ok(binary, '--settings-show', deleted, '--report', show)
    assert load(show)['generation'] == 6 and load(show)['settings']['mode'] == 'both', load(show)
    # Deleting again: the three areas are hidden already, so the counters stay and only the generation rises.
    deleted.chmod(0o444)
    again = root / 'erase-delete-again.img'
    again_plan = root / 'erase-delete-again.json'
    ok(binary, '--erase-recordings', deleted, '--erase-kind', 'delete', '--out', again, '--confirm-erase', '--report', again_plan)
    rep = load(again_plan)
    assert rep['loadedRegions'] == [] and len(rep['hiddenBefore']) == 3, rep
    assert rep['before'] == {'generation': 2, 'counters': [6, 5, 4]} and rep['after'] == {'generation': 3, 'counters': [6, 5, 4]}, rep
    assert sector(again, CONTROL)[0] == 3 and sector(again, CONTROL)[0x1FF] == 3 and counters(sector(again, CONTROL)) == [6, 5, 4]
    # A card without head headers has nothing the readers would have loaded: the counters only catch up with the generation.
    bare = root / 'erase-bare.json'
    ok(binary, '--erase-recordings', plain_card, '--erase-kind', 'delete', '--plan-only', bare)
    assert load(bare)['loadedRegions'] == [] and load(bare)['after'] == {'generation': 2, 'counters': [2, 2, 2]}, load(bare)
    out['delete_again'] = True

    # 9e. Initialize a non-default card (no layout change, so the area heads stay valid): settings, password and layout return to the dialog
    # defaults, the card ID stays, the first multi-battery byte is reset and the second one is left alone; the generation moves like a delete.
    init_in = root / 'erase-init-in.img'
    ok(binary, '--settings-apply', card, '--set', 'fps=2', '--set', 'event=3', '--set', 'audio=off', '--set', 'beep=off', '--set', 'battery=on',
       '--set', 'id=KEEP', '--set', 'password=2468', '--confirm-password', '2468', '--out', init_in)
    in_control = sector(init_in, CONTROL)
    assert in_control[0] == 1 and in_control[0x54] == 1 and in_control[0x97] == 2 and in_control[0x88] == 1
    init_in.chmod(0o444)
    init_in_hash = file_sha(init_in)
    initialised = root / 'erase-init.img'
    init_report = root / 'erase-init.json'
    ok(binary, '--erase-recordings', init_in, '--erase-kind', 'initialize', '--out', initialised, '--confirm-erase', '--report', init_report)
    assert changed_sectors(init_in, initialised) == {CONTROL, CHANNEL, BACKUP_CONTROL, BACKUP_CHANNEL}, changed_sectors(init_in, initialised)
    journal_start = JOURNAL_END - 24 * 1800 + 1
    normal_end = journal_start * 71 // 1200 * 12
    exp = bytearray(control)                    # the factory control sector (the card the non-default one was derived from)
    exp[0x21:0x29] = bytes([0x0B, 0x10, 0x27, 0x01, 0x1E, 0x00, 0x00, 0x00])           # 30 frames/s, continuous
    exp[0x29:0x31] = exp[0x31:0x39] = bytes([0x0B, 0x10, 0x27, 0x01, 0x1E, 0x00, 0x2C, 0x01])   # event 10 s + 10 s at 30 frames/s = 300 frames
    exp[0x3A:0x40] = bytes([2, 2, 2, 1, 3, 1])
    exp[0x46:0x4B] = bytes([5, 2, 5, 5, 5])
    exp[0x50] = 3
    exp[0x54] = 0                                # first multi-battery byte reset ...
    exp[0x97] = 2                                # ... the second one is left as the card had it
    exp[0x66:0x6A] = b'KEEP'                     # card ID stays
    exp[0x88:0x8B] = bytes(3)                    # password cleared
    for i, v in enumerate((FIRST_RECORD, normal_end, normal_end + 1, journal_start - 1, journal_start, JOURNAL_END)):
        word(exp, 0x1BE + 4 * i, v)
    exp[0x00] = exp[0x1FF] = 2
    for o, v in ((0x1E0, 6), (0x1E4, 5), (0x1E8, 4)):
        word(exp, o, v)
    exp_channel = bytearray(channel)
    exp_channel[0x20:0x39] = exp[0x20:0x39]
    want_control, want_channel = seal(bytes(exp), bytes(exp_channel))
    assert sector(initialised, CONTROL) == want_control and sector(initialised, BACKUP_CONTROL) == want_control, 'control sector'
    assert sector(initialised, CHANNEL) == want_channel and sector(initialised, BACKUP_CHANNEL) == want_channel, 'channel sector'
    assert init_in.stat().st_size == initialised.stat().st_size
    for n in (FIRST_RECORD, EVENT_START, JOURNAL_START):
        assert sector(initialised, n) == sector(card, n), 'recorded data must stay where it was'
    info = load(init_report)
    assert info['output']['verified'] is True and info['dataZeroed'] is False and info['after'] == {'generation': 2, 'counters': [6, 5, 4]}, info
    assert info['settingsBefore']['password'] == 2468 and info['settingsAfter']['password'] is None, info
    assert (info['settingsAfter']['cardID'], info['settingsAfter']['multiBattery'], info['settingsAfter']['eventWindowIndex']) == ('KEEP', False, 0), info
    shown = root / 'erase-init-show.json'
    ok(binary, '--settings-show', initialised, '--report', shown)
    t = load(shown)
    s = t['settings']
    assert t['regionsAreStandard'] is True and (s['mode'], s['frameRateIndex'], s['eventWindowIndex'], s['historyHoursIndex'], s['audio'], s['beep']) == ('both', 0, 0, 0, True, True), t
    assert (s['password'], s['cardID'], s['multiBattery']) == (None, 'KEEP', False), s
    gate = cli(binary, '--password-check', initialised)
    assert gate.returncode == 0 and 'locked=false' in gate.stdout, gate.stdout
    # The (0, 2) battery pair the initialization leaves behind is read back as "not connected" and a later save keeps its second byte.
    initialised.chmod(0o444)
    resaved = root / 'erase-init-resaved.img'
    ok(binary, '--settings-apply', initialised, '--set', 'beep=off', '--out', resaved)
    kept = sector(resaved, CONTROL)
    assert kept[0x54] == 0 and kept[0x97] == 2 and kept[0x50] == 0, (kept[0x54], kept[0x97], kept[0x50])
    assert file_sha(init_in) == init_in_hash and file_sha(card) == card_hash and file_sha(plain_card) == plain_hash
    out['initialize'] = {'changed_sectors': 4, 'generation_after': 2}
    return out


def run(binary, root):
    root = Path(root)
    card = root / 'settings-card.img'
    write_image(card)
    card_hash = file_sha(card)
    card.chmod(0o444)
    base_control, base_channel = sector(card, CONTROL), sector(card, CHANNEL)
    assert checksum_ok(base_control, base_channel)
    result = {}

    # 1. Show (read-only).
    shown = root / 'settings-show.json'
    ok(binary, '--settings-show', card, '--report', shown)
    info = load(shown)
    s = info['settings']
    assert (s['mode'], s['frameRateIndex'], s['eventWindowIndex'], s['audio'], s['historyHoursIndex'], s['historyDoubleRate']) == ('both', 0, 10, True, 1, False), s
    assert (s['overwriteContinuous'], s['overwriteEvent'], s['overwriteHistory'], s['beep'], s['gSensor'], s['multiBattery'], s['easyMode']) == (True,) * 5 + (False, True), s
    assert (s['shockSensitivity'], s['accelerationSensitivity'], s['steeringSensitivity'], s['cardID']) == (5, 5, 5, ''), s
    assert info['regionsAreStandard'] and info['generation'] == 1 and info['backupControlMatches'] and info['backupChannelMatches'], info
    assert info['locationSectors'] == [CONTROL, CHANNEL, BACKUP_CONTROL, BACKUP_CHANNEL], info['locationSectors']
    assert info['commandFiles'] == {'available': True, 'timeFileExists': False, 'angleDetectionRequested': False}, info['commandFiles']

    # 2. Plan only: nothing is written, the four sector hashes are reported.
    plan_path = root / 'settings-plan.json'
    plain = ['--set', 'audio=off', '--set', 'beep=off', '--set', 'id=ABC-123']
    ok(binary, '--settings-apply', card, *plain, '--plan-only', plan_path)
    plan = load(plan_path)
    assert plan['changesSectors'] and not plan['layoutChanged'] and plan['commandActions'] == [], plan
    assert [p['role'] for p in plan['patches']] == ['control', 'channel', 'controlBackup', 'channelBackup'], plan['patches']
    assert [p['changed'] for p in plan['patches']] == [True, False, True, False], plan['patches']
    assert {'音声記録', 'ビープ音', 'SDカードID'} <= set(plan['changes']), plan['changes']
    assert plan['patches'][0]['newSHA256'] == plan['patches'][2]['newSHA256']
    assert plan['patches'][0]['oldSHA256'] == sha(base_control)
    assert [p['sector'] for p in plan['patches']] == [CONTROL, CHANNEL, BACKUP_CONTROL, BACKUP_CHANNEL], plan['patches']

    # 3. Apply to a NEW copy: only the control sector and its backup change, in exactly the modelled bytes.
    out1 = root / 'settings-out1.img'
    report1 = root / 'settings-out1.json'
    ok(binary, '--settings-apply', card, *plain, '--out', out1, '--report', report1)
    assert out1.stat().st_size == card.stat().st_size and changed_sectors(card, out1) == {CONTROL, BACKUP_CONTROL}, changed_sectors(card, out1)
    new_control = sector(out1, CONTROL)
    assert sector(out1, BACKUP_CONTROL) == new_control and sector(out1, BACKUP_CHANNEL) == base_channel
    assert changed_offsets(base_control, new_control) - {0x12, 0x13} == {0x3F, 0x50} | set(range(0x66, 0x66 + 7)), sorted(changed_offsets(base_control, new_control))
    assert new_control[0x3F] == 2 and new_control[0x50] == 0 and new_control[0x66:0x6D] == b'ABC-123' and new_control[0x6D] == 0
    assert checksum_ok(new_control, base_channel)
    assert plan['patches'][0]['newSHA256'] == sha(new_control)
    out = load(report1)['output']
    assert out['verified'] is True and out['name'] == out1.name, out
    shown_again = root / 'settings-show-out1.json'
    ok(binary, '--settings-show', out1, '--report', shown_again)
    t = load(shown_again)['settings']
    assert (t['audio'], t['beep'], t['cardID']) == (False, False, 'ABC-123') and t['mode'] == 'both', t
    assert file_sha(card) == card_hash, 'the input image must not change'
    result['plain_edit'] = {'clone': out['usedClone'], 'changed_sectors': 2}

    # 3b. Password: a flag byte and the word 3 x password + 1639 behind the ID text, confirmed like the dialog, cleared back to the exact bytes.
    pw_out = root / 'settings-pw.img'
    ok(binary, '--settings-apply', card, '--set', 'password=1234', '--confirm-password', '1234', '--out', pw_out)
    pw_control = sector(pw_out, CONTROL)
    assert changed_offsets(base_control, pw_control) - {0x12, 0x13} == {0x88, 0x89, 0x8A}, sorted(changed_offsets(base_control, pw_control))
    assert pw_control[0x88:0x8B] == bytes([1]) + struct.pack('<H', 3 * 1234 + 1639) and checksum_ok(pw_control, base_channel)
    assert sector(pw_out, BACKUP_CONTROL) == pw_control and sector(pw_out, CHANNEL) == base_channel
    assert changed_sectors(card, pw_out) == {CONTROL, BACKUP_CONTROL}, changed_sectors(card, pw_out)
    shown_pw = root / 'settings-show-pw.json'
    ok(binary, '--settings-show', pw_out, '--report', shown_pw)
    assert load(shown_pw)['settings']['password'] == 1234 and info['settings']['password'] is None
    pw_bad = root / 'settings-pw-bad.img'
    for extra in (['--set', 'password=1234'], ['--set', 'password=1234', '--confirm-password', '1235'],
                  ['--set', 'password=999', '--confirm-password', '999'], ['--set', 'password=12a4', '--confirm-password', '12a4'],
                  ['--set', 'password=12345', '--confirm-password', '12345'], ['--set', 'password=0999', '--confirm-password', '0999']):
        refused(binary, '--settings-apply', card, *extra, '--out', pw_bad)
        assert not pw_bad.exists(), extra
    # The card-open gate of the app: a card with a password loads only with the right one; a card without one loads freely.
    gate = cli(binary, '--password-check', pw_out, '--card-password', '1234')
    assert gate.returncode == 0 and 'load=allowed' in gate.stdout, (gate.stdout, gate.stderr)
    for typed in (['--card-password', '1235'], ['--card-password', ''], []):
        refused_gate = cli(binary, '--password-check', pw_out, *typed)
        assert refused_gate.returncode == 1 and 'load=refused' in refused_gate.stdout, (typed, refused_gate.stdout)
    free = cli(binary, '--password-check', card)
    assert free.returncode == 0 and 'locked=false' in free.stdout, free.stdout
    # Clearing needs its own confirmation and gives back the byte-identical sector.
    pw_out.chmod(0o444)
    refused(binary, '--settings-apply', pw_out, '--set', 'password=none', '--out', pw_bad)
    assert not pw_bad.exists()
    pw_cleared = root / 'settings-pw-cleared.img'
    ok(binary, '--settings-apply', pw_out, '--set', 'password=none', '--confirm-clear-password', '--out', pw_cleared)
    assert sector(pw_cleared, CONTROL) == base_control and sector(pw_cleared, BACKUP_CONTROL) == base_control
    # Card ID and password side by side; saving the unchanged password is not a change.
    pw_both = root / 'settings-pw-both.img'
    ok(binary, '--settings-apply', card, '--set', 'id=' + 'Z' * 24, '--set', 'password=9999', '--confirm-password', '9999', '--out', pw_both)
    both = sector(pw_both, CONTROL)
    assert both[0x66:0x7E] == b'Z' * 24 and both[0x7E:0x88] == bytes(10) and both[0x88:0x8B] == bytes([1]) + struct.pack('<H', 3 * 9999 + 1639)
    pw_both.chmod(0o444)
    refused(binary, '--settings-apply', pw_both, '--set', 'password=9999', '--out', pw_bad)
    assert not pw_bad.exists()
    result['password'] = {'changed_sectors': 2, 'gate_checked': True, 'cleared_identical': True}

    # 3c. 初期設定に戻す: the dialog's defaults (10+10 s, 24 h, ...), card ID / password / multi-battery kept, history change = layout change.
    reset_in = root / 'settings-reset-in.img'
    ok(binary, '--settings-apply', card, '--set', 'mode=both', '--set', 'fps=2', '--set', 'audio=off', '--set', 'beep=off', '--set', 'battery=on',
       '--set', 'id=KEEP', '--set', 'password=2468', '--confirm-password', '2468', '--out', reset_in)
    reset_in.chmod(0o444)
    reset_out = root / 'settings-reset-out.img'
    report_reset = root / 'settings-reset.json'
    ok(binary, '--settings-apply', reset_in, '--set', 'reset=defaults', '--out', reset_out, '--report', report_reset)
    rep = load(report_reset)
    after = rep['after']
    assert (after['mode'], after['frameRateIndex'], after['eventWindowIndex'], after['historyHoursIndex'], after['historyDoubleRate'], after['audio'], after['beep']) == ('both', 0, 0, 0, False, True, True), after
    assert (after['cardID'], after['password'], after['multiBattery']) == ('KEEP', 2468, True), after
    assert rep['layoutChanged'] is True and rep['regionsAreStandard'] is True, rep
    result['reset_defaults'] = True

    # 4. Layout change: event-only, slower rate clamped, region table recomputed, generation 1 -> 2.
    out2 = root / 'settings-out2.img'
    ok(binary, '--settings-apply', card, '--set', 'fps=7', '--set', 'mode=event', '--out', out2)
    assert changed_sectors(card, out2) == {CONTROL, CHANNEL, BACKUP_CONTROL, BACKUP_CHANNEL}, changed_sectors(card, out2)
    expected = bytearray(base_control)
    expected[0x21:0x29] = bytes([0x0B, 0xB0, 0x36, 0x01, 0x01, 0, 0, 0])
    for o in (0x29, 0x31):
        expected[o:o + 8] = bytes([0x0B, 0xB0, 0x36, 0x01, 0x01, 0, 30, 0])
    expected[0x3A], expected[0x3E] = 1, 2
    for i, v in enumerate((0, 0, FIRST_RECORD, JOURNAL_START - 1, JOURNAL_START, JOURNAL_END)):
        word(expected, 0x1BE + 4 * i, v)
    expected[0x00] = expected[0x1FF] = 2
    for o in (0x1E0, 0x1E4, 0x1E8):
        word(expected, o, 2)
    expected_channel = bytearray(base_channel)
    expected_channel[0x20:0x39] = expected[0x20:0x39]
    want_control, want_channel = seal(bytes(expected), bytes(expected_channel))
    assert sector(out2, CONTROL) == want_control and sector(out2, CHANNEL) == want_channel
    assert sector(out2, BACKUP_CONTROL) == want_control and sector(out2, BACKUP_CHANNEL) == want_channel
    # Choosing the slower rate AFTER event-only is refused (the dialog does not offer it).
    late = root / 'settings-late.img'
    refused(binary, '--settings-apply', card, '--set', 'mode=event', '--set', 'fps=7', '--out', late)
    assert not late.exists()
    # A second layout change keeps the raised generation.
    out2b = root / 'settings-out2b.img'
    out2.chmod(0o444)
    ok(binary, '--settings-apply', out2, '--set', 'history-hours=24', '--out', out2b)
    assert sector(out2b, CONTROL)[0] == 2 and checksum_ok(sector(out2b, CONTROL), sector(out2b, CHANNEL))
    result['layout_edit'] = {'generation_after': 2, 'changed_sectors': 4}

    # 5. Command files: TIME.INI and SELFADJ.INI are created on the copy through a FAT16 writer, nothing else moves.
    out3 = root / 'settings-out3.img'
    report3 = root / 'settings-out3.json'
    ok(binary, '--settings-apply', card, '--set', 'time=2026-03-04T05:06:07', '--set', 'angle=on', '--out', out3, '--report', report3)
    assert changed_sectors(card, out3) <= set(range(1, 1 + PARTITION_SECTORS)), 'only the FAT16 partition may change'
    for n in (CONTROL, CHANNEL, BACKUP_CHANNEL, BACKUP_CONTROL):
        assert sector(out3, n) == sector(card, n)
    f, names = check_volume(volume_bytes(out3))
    assert set(names) == {b'.          ', b'..         ', b'VERSION INI', b'TIME    INI', b'SELFADJ INI'}, names
    assert f.read(names[b'TIME    INI']) == b'[SET]\r\nLOCALTIME=2026.03.04;05:06:07' and names[b'TIME    INI']['size'] == 36
    assert names[b'SELFADJ INI']['size'] == 0 and names[b'SELFADJ INI']['cluster'] == 0
    assert f.read(names[b'VERSION INI']) == VERSION_TEXT
    actions = load(report3)['commandActions']
    assert [a['action'] for a in actions] == ['writeTime', 'requestAngleDetection'], actions
    result['command_files_created'] = True

    # Re-applying the same request is a no-op; changing the time rewrites the file in place.
    noop = root / 'settings-noop.json'
    out3.chmod(0o444)
    ok(binary, '--settings-apply', out3, '--set', 'time=2026-03-04T05:06:07', '--set', 'angle=on', '--plan-only', noop)
    assert load(noop)['commandActions'] == [] and load(noop)['changesSectors'] is False
    nothing = root / 'settings-nothing.img'
    refused(binary, '--settings-apply', out3, '--set', 'time=2026-03-04T05:06:07', '--out', nothing)
    assert not nothing.exists()
    out3b = root / 'settings-out3b.img'
    ok(binary, '--settings-apply', out3, '--set', 'time=2027-12-31T23:59:58', '--out', out3b)
    f, names = check_volume(volume_bytes(out3b))
    assert f.read(names[b'TIME    INI']) == b'[SET]\r\nLOCALTIME=2027.12.31;23:59:58' and b'SELFADJ INI' in names

    # 6. Removal frees the entries and clusters again.
    out4 = root / 'settings-out4.img'
    ok(binary, '--settings-apply', out3, '--set', 'time=none', '--set', 'angle=off', '--out', out4)
    f, names = check_volume(volume_bytes(out4))
    assert set(names) == {b'.          ', b'..         ', b'VERSION INI'}, names
    _, deleted = f.directory(2)
    assert {d['name'][1:] for d in deleted} >= {b'IME    INI', b'ELFADJ INI'}, deleted
    result['command_files_removed'] = True

    # 7. Refusals leave no output behind and never touch the input.
    existing = root / 'settings-existing.img'
    existing.write_bytes(b'keep')
    refused(binary, '--settings-apply', card, '--set', 'audio=off', '--out', existing)
    assert existing.read_bytes() == b'keep'
    refused(binary, '--settings-apply', card, '--set', 'audio=off', '--out', card)
    for bad in (['id=' + 'X' * 25], ['bogus=1'], ['fps=9'], ['sensitivity=0'], ['mode=sideways'], ['time=yesterday']):
        target = root / 'settings-bad.img'
        refused(binary, '--settings-apply', card, '--set', bad[0], '--out', target)
        assert not target.exists(), bad
    assert file_sha(card) == card_hash, 'the input image must not change'
    result['refusals'] = True

    # 9. 録画データ削除 / 記録設定データ初期化: generation byte + region counters (+ settings) on a NEW copy, no recorded data touched.
    result['erase'] = erase_checks(binary, root, card, card_hash)

    # 8. macOS's own FAT checker on the partition after create / delete (informational: recorded, not asserted).
    fsck = shutil.which('fsck_msdos') or '/sbin/fsck_msdos'
    checks = {}
    for name, path in (('created', out3), ('removed', out4)):
        part = root / ('settings-part-%s.img' % name)
        part.write_bytes(read_range(path, 512, PARTITION_SECTORS * 512))
        try:
            p = subprocess.run([fsck, '-n', str(part)], capture_output=True, text=True, timeout=60)
            checks[name] = {'exit': p.returncode, 'tail': (p.stdout + p.stderr)[-300:]}
        except Exception as error:  # noqa: BLE001 - recorded as evidence
            checks[name] = {'error': str(error)[-200:]}
    result['fsck_msdos'] = checks
    return result
