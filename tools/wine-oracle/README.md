# Wine oracle (analysis tooling, not part of the app)

The original Windows application can be run under Wine on a Linux machine and used as an **oracle**: change single
sectors of a *copy* of a card image, let the original read that copy, and look at what it shows. This is how the event
list label rule, the journal (常時録画) start/duration rule and the BAK part layout were checked against the original
instead of being guessed. The results are recorded in `docs/validation-history.md`, `docs/validation-bak.md` and
`docs/windows-bak-format.md`.

## Rules

* Never point anything here at the original card or the original image. Work on a copy and keep a restore journal
  (`patchevt.py` writes one; `patchevt.py restore` puts every patched byte back).
* The card image, the original executable and its hooked copy, screenshots (`shots/`), `hook.log`, and the journals
  contain private drives, positions and settings. **None of them are committed** and none of them leave the analysis
  machine. Sector numbers and counters of a real card are not copied into tests or docs either.
* `hook.c` has a placeholder image path (`IMG`); set it for the build only.
* Nothing in here is meant to touch a physical drive: the hook maps the configured image *file* as the drive and every
  other open passes through unchanged. Do not run it on a machine that has the original card or a device attached.

## Layout (defaults, override with the environment)

| variable | default | meaning |
|---|---|---|
| `ORACLE_DIR` | `/tmp/wine-try` | work directory: `app/` (original application directory with the hooked executable), `prefix2/` (Wine prefix), `wine-*/` (Wine runtime), `hook/` (hook sources), `shots/`, `hook.log` |
| `ORACLE_INV` | `/tmp/inv` | directory with the helper scripts of this folder (`patchevt.py`, `patch6.py`, `patch7.py`, …) |
| `ORACLE_IMG` | – | working copy of the card image (needed by `patchevt.py`, `open_card.sh`) |
| `ORACLE_EVENT_STARTS` | `[]` | JSON list with the first D103 sector of every event of that image (event index → start for `patchevt.py`) |
| `ORACLE_JOURNAL` | `$ORACLE_INV/evt_backup.json` | restore journal |
| `ORACLE_LOCALES`, `ORACLE_XVFB`, `SCREEN` | – | optional ja_JP locale directory, Xvfb binary, and screen geometry (the recorded click coordinates assume 1920x1080) |

## Files

| file | purpose |
|---|---|
| `pehook.py` | adds an import of `hook.dll!HookInit` to a copy of the original PE32 executable (`inspect` / `patch`) |
| `hook.c`, `build_hook.sh` | freestanding i686 hook DLL (clang-18 + lld-link-18): presents the image as `\\.\PHYSICALDRIVE1` / `E:` and logs card reads |
| `patch1.py` … `patch7.py` | successive source patches of `hook.c` (more logging: read positions, accumulator calls `AT`, last reads and the caller's stack frame) |
| `run_p5.sh`, `run_p6.sh`, `run_p7.sh` | build the hook with patches applied and start one experiment |
| `restart.sh` | start the original in the private prefix (fonts mapped to one CJK font, optional Xvfb) |
| `open_card.sh` | restart, open the card with the recorded UI clicks, then run `post.json` if present |
| `ui.py` | xdotool/ImageMagick driver (`click`, `key`, `type`, `shot`, `montage`, …) |
| `patchevt.py` | patch sectors of the working copy with an undo journal: `abs`, `pk` (header + mirror pair) and per-event `all` / `first` / `blk` / `seq` rules |
| `exp_evt.sh` | one complete experiment: restore, patch, restart, load the card, crop the event tab |
| `atl2.py` | summarise the `AT` records of `hook.log` |

## What a valid experiment needs

1. A pristine copy of the card image; note which sectors are patched (the journal does this) and restore afterwards.
2. Patches must hit **both copies** of a packet header (D101 header and D102 mirror) when the question is about
   packet fields; the original reads one of them and which one is part of what is being established.
3. Change one thing at a time and keep a control run without a patch. The original may take values from a different
   place than a first guess (the trigger label comes from the post block trailer, not the packet headers).
4. Record what was found in `docs/validation-history.md` in generic terms (field offsets, rules), without the data
   of the card used.
