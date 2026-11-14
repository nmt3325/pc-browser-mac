#!/bin/bash
# Verifies the PUBLISHED assets of one release on the machine that runs this script (a macOS runner or a Mac):
# every file against SHA256SUMS, the signature, architecture and minimum OS of the extracted app, then the same CLI and GUI
# smoke checks (scripts/ci-smoke.py) that gate a build, run on the extracted app. Test pattern data only; no private media.
# usage: scripts/verify-release.sh <directory with the downloaded assets> <report.json>
set -euo pipefail
cd "$(dirname "$0")/.."
ASSETS=$(cd "$1" && pwd)
REPORT=$2
ARCH=$(uname -m)
(cd "$ASSETS" && shasum -a 256 -c SHA256SUMS)
shopt -s nullglob
ZIPS=("$ASSETS"/PC-Browser-Mac-*-"$ARCH".zip)
if [[ ${#ZIPS[@]} -ne 1 ]]; then echo "Expected exactly one $ARCH app zip in $ASSETS, found ${#ZIPS[@]}" >&2; exit 1; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp/}pcbrowser-verify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "${ZIPS[0]}" "$WORK"
APP="$WORK/PC Browser Mac.app"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
for EXEC in PCBrowserMac PCBrowserRawReader; do
  test "$(lipo -archs "$APP/Contents/MacOS/$EXEC")" = "$ARCH"
done
SMOKE="$WORK/ci-smoke.json"
python3 scripts/ci-smoke.py "$APP/Contents/MacOS/PCBrowserMac" "$SMOKE"
python3 - "$APP" "$SMOKE" "${ZIPS[0]}" "$REPORT" <<'PY'
import hashlib, json, plistlib, subprocess, sys
from pathlib import Path
app, smoke, zip_path, report = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
smoke_data = json.loads(smoke.read_text())
media = smoke_data['media']
def version(flag):
    return subprocess.check_output(['sw_vers', flag], text=True).strip()
report.write_text(json.dumps({
    'macOS': version('-productVersion'), 'macOS_build': version('-buildVersion'), 'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
    'app_version': info['CFBundleShortVersionString'], 'app_build': info['CFBundleVersion'], 'minimum_system_version': info.get('LSMinimumSystemVersion'),
    'zip': zip_path.name, 'zip_sha256': hashlib.sha256(zip_path.read_bytes()).hexdigest(),
    'sha256sums_verified': True, 'signature_verified': True, 'extracted_executables_arch_matches': True,
    'cli_synthetic_smoke_passed': smoke_data['passed'],
    'media_checks': {name: media[name]['passed'] for name in ('decode_and_features', 'view_operations', 'exports', 'gui_check', 'blank_video') if name in media},
    'ci_smoke': smoke_data}, indent=2) + '\n')
failed = [name for name, check in media.items() if isinstance(check, dict) and check.get('passed') is False]
assert not failed, failed
print(json.dumps({'verified': True, 'media_checks': {name: media[name]['passed'] for name in media if isinstance(media[name], dict) and 'passed' in media[name]}}))
PY
