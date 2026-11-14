#!/usr/bin/env python3
"""Exercise the extracted app CLI using generated headers, never private SD data."""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pngread
import settings_smoke
import synthetic_media

EXPECTED_MEDIA_IMAGE_SHA256 = 'd1f47ab10c5026347b8a7a4a5398a8151e034d2ecbd5586e22bb540796e9526f'


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


def classify(rgb):
    """Colour class of a decoded pixel. VideoToolbox applies the BT.709 matrix, so exact equality is not required."""
    r, g, b = rgb
    if r > 200 and g > 200 and b > 200:
        return 'white'
    if r < 40 and g < 40 and b < 40:
        return 'black'
    if r > 170 and g < 100 and b < 100:
        return 'red'
    if g > 150 and r < 100 and b < 100:
        return 'green'
    if b > 170 and r < 100 and g < 100:
        return 'blue'
    return 'other'


def png_samples(path):
    width, height, pixel = pngread.read_png(path)
    return {'size': [width, height],
            'classes': {name: classify(pixel(x, y)) for name, (x, y, _) in synthetic_media.SAMPLES.items()}}


# Expected picture after each display operation (the generated pattern has four distinct quadrants).
ORIGINAL_CLASSES = {'front_top': 'red', 'rear_top': 'green', 'front_bottom': 'blue', 'rear_bottom': 'white'}
VIEW_OPERATION_CLASSES = {
    'flipH': {'front_top': 'green', 'rear_top': 'red', 'front_bottom': 'white', 'rear_bottom': 'blue'},
    'flipV': {'front_top': 'blue', 'rear_top': 'white', 'front_bottom': 'red', 'rear_bottom': 'green'},
    'cw:180': {'front_top': 'white', 'rear_top': 'blue', 'front_bottom': 'green', 'rear_bottom': 'red'},
    'flipH,cw:180': {'front_top': 'blue', 'rear_top': 'white', 'front_bottom': 'red', 'rear_bottom': 'green'},
}


def run_cli(binary, *arguments, timeout=300):
    process = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, timeout=timeout)
    if process.returncode:
        raise RuntimeError('exit %d: %s' % (process.returncode, (process.stdout + process.stderr)[-1500:]))
    return process


def load_json(path):
    return json.loads(Path(path).read_text())


def attempt(results, name, strict, function):
    """Run one media check. Unavailable system media frameworks are recorded unless strict mode is requested."""
    try:
        results[name] = dict(function(), passed=True)
    except Exception as error:  # noqa: BLE001 - the failure text is the evidence
        if strict:
            raise
        results[name] = {'passed': False, 'error': str(error)[-1800:]}


def media_smoke(binary, root, strict, gui_strict=False, evidence=None):
    """Decode and export a generated H.264 + PCM + GPS card image (a test pattern, never private media)."""
    image = root / 'synthetic-media.img'
    original = synthetic_media.build()
    image.write_bytes(original)
    image.chmod(0o444)
    digest = hashlib.sha256(original).hexdigest()
    results = {'image_bytes': len(original), 'image_sha256': digest, 'image_matches_reference': digest == EXPECTED_MEDIA_IMAGE_SHA256,
               'strict': strict}
    # 1. Header-only structure check: no system video/audio framework is involved, so it is always strict.
    structure = root / 'media-structure.json'
    run_cli(binary, '--inspect', image, '--catalog-only', '--load-all', '--report', structure)
    structure_report = load_json(structure)
    assert (structure_report['recordings'], structure_report['storage_blocks'], structure_report['indexed_frames_estimate']) == (1, 3, 120), structure_report
    assert structure_report['validated_frames'] == 120 and structure_report['input_size_and_mtime_unchanged'], structure_report
    results['structure'] = {'recordings': 1, 'storage_blocks': 3, 'validated_frames': 120, 'passed': True}

    def decode_and_features():
        report, raw = root / 'media-decode.json', root / 'media-raw.png'
        run_cli(binary, '--inspect', image, '--decode-check', '--features-check', '--max-decode', '120', '--png', raw, '--report', report)
        data = load_json(report)
        assert data['native_videotoolbox_decoded_frames'] == 120 and (data['width'], data['height']) == (1280, 540), data
        assert data['first_recording_frames'] == 120 and data['first_recording_blocks'] == 3 and data['valid_gps_frames'] == 120, data
        assert data['raw_sensor_frames'] == 120 and abs(data['nominal_fps'] - 30) < 1e-6 and abs(data['timeline_seconds'] - 4) < 0.05, data
        assert data['audio_format'] == {'sample_rate': 8000, 'bits': 8, 'channels': 1} and data['audio_pcm_bytes'] == 32000, data
        assert abs(data['audio_seconds'] - 4) < 0.01 and abs(data['audio_minus_video_seconds']) < 0.05, data
        assert data['input_size_and_mtime_unchanged'], data
        samples = png_samples(raw)
        assert samples['size'] == [1280, 540] and samples['classes'] == ORIGINAL_CLASSES, samples
        return {'decoded_frames': 120, 'size': [1280, 540], 'gps_frames': 120, 'audio_pcm_bytes': 32000,
                'native_audio_prepared': data.get('native_audio_prepared'), 'picture_classes': samples['classes']}

    def view_operations():
        checked = {}
        for script, expected in VIEW_OPERATION_CLASSES.items():
            report, output = root / 'view-op.json', root / ('view-op-' + script.replace(':', '').replace(',', '_') + '.png')
            report.unlink(missing_ok=True)
            run_cli(binary, '--inspect', image, '--decode-check', '--max-decode', '1', '--view-ops', script, '--png', output, '--report', report)
            data = load_json(report)
            assert data['view_ops']['script'] == script and data['native_videotoolbox_decoded_frames'] == 1, data
            samples = png_samples(output)
            assert samples['classes'] == expected, (script, samples)
            checked[script] = samples['classes']
        refused = subprocess.run([str(binary), '--inspect', str(image), '--decode-check', '--max-decode', '1', '--view-ops', 'cw:0'], capture_output=True, text=True, timeout=120)
        assert refused.returncode != 0, 'angle 0 must be refused'
        return {'operations': checked, 'invalid_angle_refused': True}

    def exports():
        folder = root / 'exports'
        folder.mkdir()
        common = ['--inspect', image, '--max-decode', '1']
        report = folder / 'prefix.json'
        run_cli(binary, *common, '--export-prefix', folder / 'out', '--report', report)
        data = load_json(report)
        assert len(data['metal_projection_modes']) == 9, data
        for name in ('csv', 'gpx', 'kml', 'wav'):
            assert (folder / ('out.' + name)).stat().st_size > 100, name
        assert (folder / 'out.wav').stat().st_size == 32044
        assert len(list(folder.glob('out-*.png'))) == 9
        movie_report = folder / 'movie.json'
        run_cli(binary, *common, '--movie', folder / 'movie.mp4', '--frames', '90', '--report', movie_report)
        movie = load_json(movie_report)
        assert movie['movie_export']['frames'] == 90 and abs(movie['movie_export']['duration'] - 3) < 0.1, movie
        assert movie['movie_export']['video_tracks'] == 1 and movie['movie_export']['audio_tracks'] == 1, movie
        assert movie['movie_size'] == {'width': 1280, 'height': 720}, movie
        avi_report = folder / 'avi.json'
        run_cli(binary, *common, '--avi', folder / 'movie.avi', '--frames', '90', '--report', avi_report)
        avi = load_json(avi_report)['avi_export']
        assert avi['frames'] == 90 and avi['audioSampleFrames'] == 24000 and avi['segments'] == 1 and avi['width'] == 1280, avi
        head = (folder / 'movie.avi').read_bytes()[:4096]
        assert head[:4] == b'RIFF' and head[8:12] == b'AVI ' and b'MJPG' in head, head[:64]
        sheet_report = folder / 'sheet.json'
        run_cli(binary, *common, '--print-pdf', folder / 'print.pdf', '--sequence-dir', folder / 'sequence', '--frames', '90',
                '--frame-step', '10', '--report', sheet_report)
        sheet = load_json(sheet_report)
        assert sheet['print_pdf']['frames'] == 9 and sheet['print_pdf']['pages'] == 3, sheet
        assert sheet['still_sequence']['frames'] == 9 and len(list((folder / 'sequence').glob('*.png'))) == 9, sheet
        assert (folder / 'print.pdf').read_bytes()[:5] == b'%PDF-'
        recording_report = folder / 'recording.json'
        run_cli(binary, *common, '--recording-report-pdf', folder / 'recording.pdf', '--report', recording_report)
        page = load_json(recording_report)
        # A continuous report has no reference images (only event reports carry the five pictures).
        assert page['report_reference_frames'] == [] and page['report_page']['kind'] == 'continuous' and page['report_page']['pages'] == 1, page
        assert (folder / 'recording.pdf').read_bytes()[:5] == b'%PDF-'
        return {'projection_pngs': 9, 'wav_bytes': 32044, 'movie': movie['movie_export'], 'avi': avi,
                'print_pages': sheet['print_pdf']['pages'], 'sequence_frames': 9, 'report_pdf_pages': 1}

    def gui_check():
        """Open the real window on the generated image and run the GUI self-check (playback, audio clock, map, projections, view operations)."""
        folder = root / 'gui'
        folder.mkdir()
        report = folder / 'report.json'
        process = subprocess.run([str(binary), '--image', str(image), '--ui-check-report', str(report), '--ui-snapshot', str(folder / 'main.png'),
                                  '--ui-check-extra'], capture_output=True, text=True, timeout=420)
        data = load_json(report) if report.exists() else {}
        try:
            assert process.returncode == 0 and data.get('passed') is True, (process.returncode, data.get('error'), process.stderr[-600:])
            view = data['view_operations']
            assert not [k for k, v in view.items() if isinstance(v, str) and v.startswith('FAILED')], view
            assert sum(1 for v in view.values() if v == 'passed') >= 10, view
            assert data['route_points'] == 120 and data['raw_sensor_points'] == 720 and data['reverse_playback_decreased'] is True, data
            assert data['continuously_played_boundaries'] == [40, 80] and data['audio_prepared'] is True, data
            assert len(data['projection_modes']) == 10 and all(data['projection_modes'].values()), data  # nine Metal modes + the 16分割 frame-history sheet
            assert sorted(data['legacy_report_pages']) == ['continuous', 'event'], data.get('legacy_report_pages')
            for name in ('main.png', 'view-ops-flip-rotate.png', 'detached-view.png', 'recording-report.png', 'report-page-event.png', 'report-page-continuous.png'):
                assert (folder / name).stat().st_size > 5000, name
        finally:
            if evidence:
                target = Path(evidence)
                target.mkdir(parents=True, exist_ok=True)
                for item in list(folder.glob('*.png')) + list(folder.glob('*.json')):
                    (target / item.name).write_bytes(item.read_bytes())
                (target / 'stderr-tail.txt').write_text(process.stderr[-4000:])
        return {'view_operations_passed': sum(1 for v in view.values() if v == 'passed'), 'route_points': data['route_points'],
                'raw_sensor_points': data['raw_sensor_points'], 'continuously_played_boundaries': data['continuously_played_boundaries'],
                'projection_modes': len(data['projection_modes']), 'reverse_playback_decreased': True,
                'playback_advanced_to_frame': data.get('playback_advanced_to_frame')}

    attempt(results, 'decode_and_features', strict, decode_and_features)
    if results['decode_and_features']['passed']:
        attempt(results, 'view_operations', strict, view_operations)
        attempt(results, 'exports', strict, exports)
        attempt(results, 'gui_check', gui_strict, gui_check)
    else:
        results['view_operations'] = results['exports'] = results['gui_check'] = {'passed': False, 'error': 'skipped: system H.264 decoder unavailable'}
    assert hashlib.sha256(image.read_bytes()).hexdigest() == digest, 'input image changed'
    return results


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
        # Windows-compatible BAK output (BDRBACKUP___ run folder): write the generated card, verify it byte for byte,
        # re-open the run folder as a card source and write it again; the second run must be byte-identical to the first.
        bak_one, bak_two = root / 'bak-one', root / 'bak-two'
        bak_one.mkdir()
        bak_two.mkdir()
        bak_options = ['--bak-created', '20261113_223419', '--bak-time-zone', 'Asia/Tokyo', '--bak-key-index', '116']
        bak_report = root / 'bak-write.json'
        run_cli(binary, '--inspect', image, '--catalog-only', '--bak-write', bak_one, *bak_options, '--bak-verify', '--report', bak_report, timeout=120)
        bak = load_json(bak_report)['bak_write']
        assert bak['folder'] == '20261113_223419' and bak['parts'] == 1 and bak['chunks'] == 3 and bak['reopened_matches'], bak
        assert bak['verified_extents'] == 6 and bak['mirror_pair_included'] is False and bak['header_pairs'] == 3, bak
        written = sorted((bak_one / bak['folder']).glob('*.bak'))
        assert len(written) == 1 and written[0].name == bak['part_files'][0], (written, bak)
        head = written[0].read_bytes()
        assert head[:12] == b'BDRBACKUP___' and head[22] == 116 and list(head[16:22]) == [26, 11, 13, 22, 34, 19], head[:48]
        assert int.from_bytes(head[24:32], 'little') == 6 and int.from_bytes(head[32:40], 'little') == len(head) == 48 + 6 * 32 + bak['bytes'], bak
        assert hashlib.sha256(image.read_bytes()).digest() == hashlib.sha256(original).digest()
        again_report = root / 'bak-again.json'
        run_cli(binary, '--inspect', bak_one / bak['folder'], '--catalog-only', '--bak-write', bak_two, *bak_options, '--bak-verify', '--report', again_report, timeout=120)
        again_bak = load_json(again_report)
        assert again_bak['windows_backup']['parts'] == 1 and again_bak['bak_write']['reopened_matches'], again_bak
        second = sorted((bak_two / bak['folder']).glob('*.bak'))
        assert [f.name for f in second] == [written[0].name] and second[0].read_bytes() == head, 'BAK -> BAK must be byte-identical'
        existing = subprocess.run([str(binary), '--inspect', str(image), '--catalog-only', '--bak-write', str(bak_one), *bak_options], capture_output=True, text=True, timeout=60)
        assert existing.returncode != 0 and sorted(p.name for p in (bak_one / bak['folder']).iterdir()) == [written[0].name], 'existing BAK run folder must be refused'
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
        # Display operations (flip / rotate / zoom / pan) rendered with CoreGraphics and compared pixel by pixel.
        view_path = root / 'view-check.json'
        view_run = subprocess.run([str(binary), '--view-check', str(view_path)], capture_output=True, text=True, timeout=60)
        view_report = json.loads(view_path.read_text()) if view_path.exists() else {'passed': False, 'checks': []}
        assert view_run.returncode == 0 and view_report['passed'], (view_run.stderr, [c for c in view_report['checks'] if not c['passed']])
        assert {c['name'] for c in view_report['checks']} >= {'flipHorizontal', 'flipVertical', 'rotateClockwise90', 'areaZoomTopLeft', 'zoom2PanRight'}
        # Recording settings (記録設定) on a generated card: sector layout, checksum, region table and CONFIG command files.
        recording_settings = settings_smoke.run(binary, root)
        media = media_smoke(binary, root, os.environ.get('PCB_ALLOW_MEDIA_UNAVAILABLE') != '1', os.environ.get('PCB_REQUIRE_GUI_CHECK') == '1',
                            os.environ.get('PCB_GUI_EVIDENCE_DIR'))
    summary = {'passed': True, 'scope': 'Generated card headers plus a generated H.264/PCM/GPS test pattern; no physical SD or private media; GUI is not exercised in CI',
               'continuous_recordings': 1, 'storage_blocks': 3, 'indexed_frames': 6,
               'catalog_validated_frames': results[0]['validated_frames'],
               'lazy_loaded_validated_frames': results[1]['validated_frames'], 'input_sha256_unchanged': unchanged,
               'raw_search_no_video_decode': True, 'report_csv_json': True, 'image_copy_sha256_readback': True,
               'existing_copy_and_invalid_query_refused': True, 'windows_bak_write_verify_roundtrip': True,
               'legacy_inventory_commands': inventory['commands'], 'legacy_inventory_statuses': inventory['statuses'],
               'view_transform_pixel_checks': len(view_report['checks']), 'recording_settings': recording_settings, 'media': media}
    output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
