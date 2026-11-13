#!/usr/bin/env python3
"""Exercise the extracted app CLI using generated headers, never private SD data."""
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def put(data, offset, value):
    struct.pack_into('<I', data, offset, value)


def synthetic_image():
    data = bytearray(100 * 512)
    data[510:512] = b'\x55\xaa'
    data[450] = 6
    put(data, 454, 1)
    put(data, 458, 7)
    marker = b'YP_FORMAT_1.01__\0'
    data[8 * 512 + 1:8 * 512 + 18] = marker
    data[8 * 512 + 0x1ec:8 * 512 + 0x1fd] = marker
    put(data, 8 * 512 + 0x1be, 10)
    data[8 * 512 + 0x14] = 1
    previous = 41
    for block, record in enumerate((10, 22, 34)):
        meta = bytearray(512)
        # Also exercise a D103 phase with a nonzero session ordinal.
        for off, value in ((0, 0xffffd103 if block < 2 else 0xffffd105),
                           (4, record + 1000), (0x1fc, record + 1000),
                           (0x1c4, 10), (0x1e0, record), (0x98, block * 2),
                           (0x9c, 7), (0x1f8, 68)):
            put(meta, off, value)
        meta[0x16], meta[0x18], meta[0x19] = 80, 1, 8
        data[record * 512:(record + 1) * 512] = meta
        meta[0x70] = 1
        data[(record + 1) * 512:(record + 2) * 512] = meta
        for frame in range(2):
            sector = record + 2 + frame * 5
            header = bytearray(512)
            for off, value in ((0, 0xffffd101), (4, frame), (0x1fc, frame),
                               (0x1a6, 600), (0x1ac, 5), (0x1b0, sector),
                               (0x1b4, sector + 4), (0x1b8, record),
                               (0x1bc, 320), (0x1c0, previous),
                               (0x1d8, 68), (0x1dc, record + 1000), (0x1e8, 15)):
                put(header, off, value)
            header[8], header[9], header[0x1d] = 1, 2, 30
            header[10:17] = bytes((24, 1, 2, 3, 4, 5, block * 2 + frame))
            data[sector * 512:(sector + 1) * 512] = header
            put(header, 0, 0xffffd102)
            data[(sector + 4) * 512:(sector + 5) * 512] = header
            previous = sector
    return bytes(data)


def main():
    binary, output = map(Path, sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix='pcbrowser-synthetic-') as temp:
        root = Path(temp)
        image = root / 'synthetic.img'
        original = synthetic_image()
        image.write_bytes(original)
        image.chmod(0o444)
        results = []
        for load in (False, True):
            report = root / ('detail.json' if load else 'catalog.json')
            command = [str(binary), '--inspect', str(image), '--catalog-only', '--report', str(report)]
            if load:
                command.append('--load-all')
            process = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if process.returncode:
                raise RuntimeError(process.stdout + process.stderr)
            result = json.loads(report.read_text())
            assert (result['recordings'], result['storage_blocks'], result['indexed_frames_estimate']) == (1, 3, 6), result
            assert result['validated_frames'] == (6 if load else 0), result
            assert result['input_size_and_mtime_unchanged'] and result['mode'] == 'O_RDONLY', result
            assert result.get('native_videotoolbox_decoded_frames', 0) == 0
            results.append(result)
        copy = root / 'verified-copy.img'
        prefix = root / 'recording-report'
        extra_report = root / 'new-features.json'
        command = [str(binary), '--inspect', str(image), '--catalog-only', '--raw-query', '--raw-event', '0',
                   '--recording-report-prefix', str(prefix), '--report-notes', '=1+1,"備考"\nline',
                   '--copy-image', str(copy), '--report', str(extra_report)]
        process = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if process.returncode:
            raise RuntimeError(process.stdout + process.stderr)
        extra = json.loads(extra_report.read_text())
        assert extra['raw_query']['matching_frames'] == 6, extra
        assert len(extra['raw_query']['recording_ids']) == 1
        assert extra.get('native_videotoolbox_decoded_frames', 0) == 0, extra
        assert extra['image_copy']['readbackVerified'] and extra['image_copy']['bytes'] == len(original)
        assert extra['image_copy']['sha256'] == hashlib.sha256(original).hexdigest()
        assert copy.read_bytes() == original and extra['input_size_and_mtime_unchanged']
        reports = json.loads(prefix.with_suffix('.json').read_text())
        assert len(reports) == 1 and reports[0]['frames'] == 6 and reports[0]['gpsFrames'] == 0
        assert reports[0].get('meanSpeedKMH') is None and reports[0]['notes'] == '=1+1,"備考"\nline'
        assert "\"'=1+1,\"\"備考\"\"\nline\"" in prefix.with_suffix('.csv').read_text()
        # Existing-file refusal and invalid queries must fail, not be silently accepted.
        refused = subprocess.run([str(binary), '--inspect', str(image), '--catalog-only', '--copy-image', str(copy)], capture_output=True, text=True, timeout=60)
        assert refused.returncode != 0 and copy.read_bytes() == original
        invalid = subprocess.run([str(binary), '--inspect', str(image), '--catalog-only', '--raw-query', '--raw-event', '256'], capture_output=True, text=True, timeout=60)
        assert invalid.returncode != 0
        unchanged = hashlib.sha256(image.read_bytes()).digest() == hashlib.sha256(original).digest()
        assert unchanged
        # Original-menu inventory: complete, unique, and every entry carries a status and an explanation.
        inventory_path = root / 'legacy-inventory.json'
        inventory_run = subprocess.run([str(binary), '--legacy-inventory', str(inventory_path)], capture_output=True, text=True, timeout=60)
        if inventory_run.returncode:
            raise RuntimeError(inventory_run.stdout + inventory_run.stderr)
        inventory = json.loads(inventory_path.read_text())
        entries = inventory['entries']
        assert inventory['commands'] == len(entries) == len({e['id'] for e in entries}), inventory['commands']
        assert inventory['models'] == 44 and inventory['menu_bar_commands'] == 93, inventory
        assert all(e['reason'] and e['mac'] and e['status'] for e in entries)
        assert sum(inventory['statuses'].values()) == inventory['commands']
        assert next(e for e in entries if e['id'] == 370)['status'] == 'refusedByPolicy'
        again = subprocess.run([str(binary), '--legacy-inventory', str(inventory_path)], capture_output=True, text=True, timeout=60)
        assert again.returncode != 0, 'inventory output must not overwrite an existing file'
    summary = {'passed': True, 'scope': 'Generated synthetic headers only; no H.264/PCM decoding, GUI, physical SD or private media',
               'continuous_recordings': 1, 'storage_blocks': 3, 'indexed_frames': 6,
               'catalog_validated_frames': results[0]['validated_frames'],
               'lazy_loaded_validated_frames': results[1]['validated_frames'], 'input_sha256_unchanged': unchanged,
               'raw_search_no_video_decode': True, 'report_csv_json': True, 'image_copy_sha256_readback': True,
               'existing_copy_and_invalid_query_refused': True,
               'legacy_inventory_commands': inventory['commands'], 'legacy_inventory_statuses': inventory['statuses']}
    output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
