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
        unchanged = hashlib.sha256(image.read_bytes()).digest() == hashlib.sha256(original).digest()
        assert unchanged
    summary = {'passed': True, 'scope': 'Generated synthetic headers only; no H.264/PCM decoding, GUI, physical SD or private media',
               'continuous_recordings': 1, 'storage_blocks': 3, 'indexed_frames': 6,
               'catalog_validated_frames': results[0]['validated_frames'],
               'lazy_loaded_validated_frames': results[1]['validated_frames'], 'input_sha256_unchanged': unchanged}
    output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
