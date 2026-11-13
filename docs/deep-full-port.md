# Full-feature Deep investigation

Original target: PC Browser 1.9.60.0, `application-files/Program Files/PC Browser/PC Browser.exe` on korakuen. Craft Anything CLI 0.6.1 was run with `--deep --project investigation.cany`. Evidence and all binary/real-card artifacts remain outside Git.

## Fresh evidence

| Scope | Evidence ID | Coverage |
|---|---|---|
| PE resources | `ev_44aee68e52051130a044a4e9b997e9f74063c7fd4272dfa3ddc6df4ed5727983` | 1,084 entries |
| Export/backup strings | `ev_e39ce0fa71d7af74835a776a8c14d7778c33d5ed8a2939ec5dbe8a077fb29936` | 14 matches |
| Configuration/password strings | `ev_20f9759e29159db13ba9d3f5e3d129f049c28673254b34da2f77dddf523b8ff9` | 52 matches |
| Lens/NIGHT strings | `ev_3d122979669790a546b31ab801a5e99ed23794460310e584ba47e292a4dde6f1` | 10 matches |
| Sensor/trigger strings | `ev_7920585b632fd7c2d23e49800e8bcd09481791fc32ab5ab0317d2a6e919850d9` | 125 matches |

59 dialog resources contain 37 application-specific dialogs and 22 framework dialogs. Resource 102 controls still-frame range/duration, 103 exposes Motion JPEG/H.264 and individually selected subtitles, 104 exposes KML point/route/color/alpha/width/density/Earth launch, 105 exposes PC Browser/PC Viewer backups, 110–111 expose 1/4-frame paginated printing, and 120–121 expose formatting/deletion. Recording-setting dialogs are model-specific, not one universal schema.

New trace anchors: `.bak` at VA `0x8A49CC`; `BDRBACKUP___` at `0x8A5588`, referenced by `0x545B00` and `0x575690`; backup filename `0x8A5F00` referenced by `0x584850`. `config/set.ini` at `0x8A2B50`; `PASSWORD` and `PASSWORD=%d` at `0x8A4DB8`/`0x8A5130`, referenced by `0x4D82C0`; setting paths at `0x8A5F70`/`0x8A5F7C`. `NIGHT` preference references in `0x411470` are not proof of the pixel-processing implementation. Strings by themselves do not establish layouts or correctness.

## Caller/callee and independent decompiler checks

- `0x545B00` callers: `0x50CB40`, `0x584850`, `0x587E90`, `0x595540`; evidence `ev_ce5974127fd2df9835f30a6555464eafd4cb14e449e7a107dd4901ff8a0e371b`.
- `0x575690` has 28 call sites, split between `0x584850` and `0x587E90`; evidence `ev_5e9a57e78e31aaa0c58e6f9ee509d11989207734d6f69a925d836e34209afe4d`. Do not treat the builder as one universal backup layout without tracing model branches.
- Fresh Deep decompile of `0x587E90` / `0x595540`: `ev_2dcebe46678cc5b7a96d3e2df632d04879262eb9227e154405e988f644cda2e0`.
- Callees of `0x595540`, `0x575690`, `0x584850`: `ev_6dde4468794409c4e799ca913e3ca69f21ffa109bdc9e71bbd826cdd57d3b2a9`, `ev_b2292ccb98c87f7a936b3e96b8b3b64418d0f758e140bdf94d2fa012dd58362d`, `ev_bf139ee2cb12cdc2557ee3cf6c6fb46c012dd01b8f605cf3dc475e0f4ed496d2`.
- Ghidra read-only cross-checks at `0x545B00`, `0x575690`, `0x584850`, `0x50CB40`, `0x4D82C0`, `0x595FF0`, `0x596180`, `0x5A81A0`, `0x5D5270` recovered settings IO and header construction. Decompiled C is evidence, not recompiled source or proof of ABI/layout correctness.
- Setting keys observed include RECINGMODE, PRERECTIME, POSTRECTIME, PRERECINT, POSTRECINT, RECAUDIO, ACCSEN, RECMOD, GPSRECTIME, BEEPRECORD, EVENTRECPER, PASSWORD, NRMRECSM and RECEXTTIME. Values/model dependencies remain unverified.

The full dialog inventory is in `dialog-port-map.md`; it includes reports/remarks, standby schedules, person-detection settings and connection IDs rather than silently limiting the target to playback.

## Additional deep backup traces

- Constructor/lifetime checks at `0x545140`, `0x5751C0`, `0x575360`: evidence `ev_7d1ccb0ddf96afb833e98edbb7eb3745a2e34d255c49c2f88aba9da5bdd6f101`.
- IO traces `0x5769B0`, `0x5772B0`, `0x5774E0`, `0x579B10`, `0x57F5F0`: evidence `ev_c132c890a2d76eb15baf06f0a409c8ba880820bc51a0b655895abe78743c9e48`, five complete decompiles, independently checked with Ghidra.
- The reader consumes a 40-byte header: 12-byte `BDRBACKUP___` magic, 4 and 6-byte fields, a byte, a skipped byte, and two 8-byte fields. Builder and reader objects have different in-memory layouts; object offsets are not file offsets.
- Per-extent serialization passes four 8-byte values (start, inclusive end, stored offset, length) through virtual calls. This is a trace anchor, **not** a complete proven backup specification. Model branches, offsets, versions and actual original-app interoperability still need verification before enabling a BAK adapter.


## Extent reader and IO-key follow-up (read-only investigation)

- `0x545C40`, `0x6BA980`, `0x48BFB0`, `0x48C0E0`: `ev_bbd0203c53fb1ee3c614156ac1641e1748172f5ed802ba17de922375cf6f2ee9`.
- `0x48A620`, `0x4C2E30`, `0x5774E0`, `0x5772B0`: `ev_ff7561d3ac46f95377ac070508d4c6d9f47cf313752ff7dede7c947ed487f707`.
- Raw IO and backup reader `0x486FA0`, `0x487250`, `0x545B00`, `0x579B10`: `ev_b21182c289cb6af9c86cee13ac16a89182327e92e513e8ba3af6410c0076b042`.

The 8-byte wrapper read is little-endian. The caller starts the extent table at file offset 0x30, despite 40 meaningful header bytes being parsed. Each entry serializes four 8-byte quantities. The reader masks the top byte of its stored-offset quantity, computes an address translation, and separately retains the high-byte value plus one. File-part/model meaning and all extent constraints still require an original sample. Do not interpret the first 4-byte field as an established universal format version.

The `mode == 2` IO paths XOR each read byte with a byte selected from the IO object's table (`this + 0x18 + keyIndex`); the initial header call uses index 0x7A and later reads use a parsed header byte. The main constructor `0x40C420` calls IO constructor `0x488760` for the embedded object at `this + 0x94F0`. Deep evidence `ev_73d884101f294f99d9553aa94eed9d9926c7fd3b4d9216dca4257fe40f38c7b7` and `ev_221a8956965f0f71c0f8ea9348974e694015f7fdd2d4a1c35a8df33962fc300d` shows all 64 immediate DWORD stores for the 256-byte table. Its SHA-256 is `5bf74ee875ed4b81706351ef3e2faf677d16d78c9d1245494619f91952726ff4`; a read-only live original-process scan independently matches it. Entry 0x7A is zero. It is not the literal `index ^ 0x7A`. Interoperability remains unverified; no source writes have been performed.

Further Deep mapping evidence: `ev_7629fce037846eaca15836133c9f368a858c980d3a2f5a8dd697fb7c09ef5af7`. `0x489DD0` adds the selected map entry's stored-minus-virtual delta for mode 2. Importantly, the second header UInt64 at offset 32 is updated by `0x5769B0` from the stored-file cursor plus 512, **not a proven virtual disk capacity**. Never size a virtual disk from that field. Original sample/part and Windows-generated round-trip validation remain required.
