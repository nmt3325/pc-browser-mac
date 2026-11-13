#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/PC Browser Mac.app"
ARCH=$(uname -m)
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleGetInfoString' "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
for EXEC in PCBrowserMac PCBrowserRawReader; do
  test "$(lipo -archs "$APP/Contents/MacOS/$EXEC")" = "$ARCH"
done
mkdir -p dist
ZIP="$PWD/dist/PC-Browser-Mac-$VERSION-$ARCH.zip"
SOURCE="$PWD/dist/pc-browser-mac-$VERSION-source.zip"
test ! -e "$ZIP"
test ! -e "$SOURCE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
VERIFY=$(mktemp -d "${TMPDIR:-/tmp/}pcbrowser-package.XXXXXX")
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "$ZIP" "$VERIFY"
EXTRACTED="$VERIFY/PC Browser Mac.app"
codesign --verify --deep --strict "$EXTRACTED"
for EXEC in PCBrowserMac PCBrowserRawReader; do
  cmp "$APP/Contents/MacOS/$EXEC" "$EXTRACTED/Contents/MacOS/$EXEC"
done
python3 scripts/ci-smoke.py "$EXTRACTED/Contents/MacOS/PCBrowserMac" "$PWD/dist/ci-smoke.json"
git archive --format=zip --prefix="pc-browser-mac-$VERSION/" --output="$SOURCE" HEAD
python3 - "$APP" "$ARCH" "$VERSION" <<'PY'
import hashlib, json, os, plistlib, re, subprocess, sys, zipfile
from pathlib import Path
app, arch, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
dist = Path('dist')
for z in dist.glob('*.zip'):
    with zipfile.ZipFile(z) as f:
        assert f.testzip() is None
        assert not any(n.lower().endswith(('.img', '.h264', '.h265', '.pcm', '.wav', '.mp4', '.avi', '.kml', '.gpx', '.pcbbackup/')) for n in f.namelist())
        assert not any('private-' in n.lower() for n in f.namelist())
minimum = {}
for name in ('PCBrowserMac', 'PCBrowserRawReader'):
    info = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(app / 'Contents/MacOS' / name)], text=True)
    versions = re.findall(r'\bminos\s+([0-9.]+)', info)
    assert versions and all(tuple(map(int, v.split('.'))) <= (14, 0, 0) for v in versions), info
    minimum[name] = versions
log = Path('unit-tests.log')
unit_results = re.findall(r'Executed (\d+) tests, with (\d+) failures', log.read_text()) if log.exists() else []
assert unit_results and all(int(failed) == 0 for _, failed in unit_results), 'Missing successful unit test log'
tests = max(int(count) for count, _ in unit_results)
repo, run_id = os.getenv('GITHUB_REPOSITORY', ''), os.getenv('GITHUB_RUN_ID', '')
metadata = {'version': version, 'bundle_build': plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'], 'architecture': arch, 'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'workflow_run': f'https://github.com/{repo}/actions/runs/{run_id}' if repo and run_id else None,
            'macOS': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
            'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
            'minimum_macos': minimum, 'unit_tests_passed': tests, 'unit_test_failures': 0,
            'zip_signature_verified_after_extraction': True, 'extracted_executables_match': True,
            'packaged_cli_synthetic_smoke_passed': True, 'private_media_uploaded_to_ci': False,
            'notarized': False, 'real_media_GUI_and_physical_SD_retested_in_CI': False,
            'zip_files': [{'file': p.name, 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(dist.glob('*.zip'))]}
(dist / 'build-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
notes = f'''PC Browser Mac {version} ({arch})

Built by GitHub Actions from {metadata['source_commit']}.
Synthetic unit tests passed: {tests}; failures: 0.
App signature and binaries verified after ZIP extraction; packaged CLI synthetic catalog/lazy-load smoke test passed.
The app is ad-hoc signed, not Apple-notarized. macOS 14+ / Apple Silicon for the arm64 package.

This build includes continuous-recording grouping and header-only catalog/lazy loading. It does not assert full Windows parity, factory optical calibration, physical SD E2E, all-card video decoding or renewed private-media GUI validation.
Private recordings, disk images, coordinates and device settings were not uploaded to Actions or packaged.
See README.md, docs/ci-build.md, docs/session-catalog.md and docs/validation-catalog.md in the source ZIP.
'''
(dist / 'RELEASE-NOTES.txt').write_text(notes)
files = sorted(p for p in dist.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
(dist / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in files))
summary = os.getenv('GITHUB_STEP_SUMMARY')
if summary:
    with open(summary, 'a') as f:
        f.write(f"## PC Browser Mac {version}\n\n- Architecture: `{arch}`\n- Synthetic tests: **{tests} passed, 0 failed**\n- Extracted app signature / binary comparison / CLI smoke: **passed**\n- Source commit: `{metadata['source_commit']}`\n- Download: the **PC-Browser-Mac-arm64** artifact below contains the app ZIP, source ZIP, checksums and build evidence.\n\nPrivate-media GUI and physical SD validation are **not** part of this CI run.\n")
print(json.dumps({'unit_tests': tests, 'signature_and_cli_smoke': 'passed', 'zip_files': metadata['zip_files']}))
PY
(cd dist && shasum -a 256 -c SHA256SUMS)
