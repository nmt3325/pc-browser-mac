# Windows PC Browser BAK (`BDRBACKUP___`) — recovered format and writer rules

Everything below was recovered from **genuine backups written by PC Browser 1.9.60.0** (the original program, run under
Wine on a Linux machine, reading a private image of a real Q-01 card) plus static analysis of the original binary.
No private media, card images or BAK files are stored in this repository; the unit tests use synthetic cards.
"Observed" means seen in genuine files; "chosen" means the Mac implementation picked a value that is consistent with
every observation but where the original's exact rule is unknown.

## Container (one `.bak` file = one part)

| Offset | Size | Meaning |
|---|---|---|
| 0 | 12 | `BDRBACKUP___` |
| 12 | 4 | little-endian `1` |
| 16 | 6 | `yy mm dd HH MM SS`, start of the backup run in local time (the same in every part of a run; equals the run folder name) |
| 22 | 1 | key index (random per run, same in every part). The XOR byte is `xorTable[index]` (see `WindowsBackupSource.xorTable`) |
| 24 | 8 | number of extents `n` |
| 32 | 8 | file size |
| 40 | 8 | zero in every file seen |
| 48 | 32·n | extent table, XOR-ed: `start`, `last` (inclusive), `stored offset`, `length` (all UInt64, byte offsets of the 512-byte-sector card image) |
| 48+32·n | … | extent data, contiguous in table order, XOR-ed with the same byte (no checksum, no compression, no encryption beyond the fixed XOR) |

The reader (`WindowsBackupSource`) validates the magic, size, extent bounds and overlap and presents the extents as a sparse
card image (`scanRanges`); a folder of parts is merged by `WindowsBackupSet` (overlapping sectors must be byte-identical; a
part that conflicts is refused). Parts are **partial copies**: nothing between the extents exists, and the Mac never
presents a backup as a complete card image or as an integrity-checked copy.

## What a part contains (observed)

* Exactly five fixed extents: the MBR (sector 0), the control header and the sector after it (the sector pair that starts the
  recording partition, e.g. 931,770/931,771 on the test card) and the **mirror pair** (the last two sectors of the recording
  partition, e.g. 61,480,753/61,480,754). Every part repeats them.
* Then one extent per record block ("chunk"): `[D103/D105 header pair][packets][D106/D104 trailer pair]`. Packets are the
  usual D101…D102 pairs. The first chunk of a recording whose block header was overwritten by the card's ring wrap starts at
  its first intact packet (no header pair). A short block that ends at the ring wrap is an ordinary chunk.
* **Table order is stream order, not sorted**: MBR, control, control+1, chunks as the original walks the card, mirror pair.
  When the ring wraps, a higher sector range appears before a lower one (e.g. 43,419,384 before 931,772). The reader sorts.
* Frame serial numbers (`0x1D4` of every packet header) continue across recordings; the backup keeps all bytes untouched.

## Run folder and part names (observed, 13 genuine parts)

* Run folder: `<yyyyMMdd_HHmmss>` (start of the run, local time, equal to header bytes 16-21).
* Part: `<%010u counter>_<yyyyMMdd>_<HHmmss>.bak`.
  * **Counter** = serial (`0x1D4` of the packet header) of the **first intact packet of the recording that contains the part's
    first chunk, minus the ordinal of the recording's first block** (the frame index of the block's first frame inside the
    recording, `RecordBlock.metadata.frameOffset`, header offset `0x98`). In other words the serial of frame 0 of the
    recording, even when the card's ring wrap already overwrote the beginning of the recording (observed first-block
    ordinals 0, 900, 4,950, 15,750 and 68,850). `WindowsBackupWriter.startCounter(firstPacketCounter:firstBlockOrdinal:)`.
    A recording whose first block has ordinal 0 but whose first frames are damaged keeps the first intact serial (observed
    once: 389 of 450 frames of the first block intact); that is why the *metadata* ordinal, not the position of the first
    intact packet inside the block, is subtracted.
  * **Date/time** = card clock (raw packet clock, no time-zone conversion) of the part's **first packet**.
* Special case at a recording boundary where the original closed the part first (see below): the next part is named with the
  *previous* recording's counter and the clock of the previous recording's **last** packet (observed once: the second part of
  a run was named with the first recording's counter and its last-packet time although it only holds the second recording).
* Name clashes never occurred in genuine data; the writer resolves one by advancing the counter.

## How the chunk stream is cut into parts

All selected recordings form **one chunk stream** (rows of the original's list that are adjacent in the card can share a part).
The unit of the size decision is one **chunk** (a block, or - when the ring wraps in the middle of a block - the short block
at the end of the ring plus its continuation at the start of the ring, which count as one unit). A part is closed when:

1. the next chunk would push the chunk bytes over the limit **L**. Every size-decided boundary seen is consistent with
   246,630,400 <= L < 246,795,776 bytes; the Mac uses **246,681,600** (481,800 sectors). **There is no chunk-count limit**: the
   genuine parts hold 6-12 chunks (a 12-chunk part has 17 table entries); an earlier "11 chunks maximum" rule was a wrong
   inference from parts that happened to be size-limited, or
2. a **recording boundary** is reached and the part is already so full that `bytes + R > L`. Observations: the part was closed
   with 212,123,648 chunk bytes although the next chunk (21,054,464 bytes) would still have fitted; it continued with
   196,988,928 (next chunk 21,141,504) and with 153,884,160. Any `R` in (34,557,952, 49,692,672] reproduces all three; the Mac
   uses **R = 40 MiB (41,943,040)**. *The original's exact rule at recording boundaries is not known* (a rule such as
   "remaining space >= two typical chunks" would fit as well). `WindowsBackupOptions` exposes both numbers.

Ordinary splits inside a recording use only rule 1. Parts of a run can therefore differ from the original's only
for recording boundaries where the filled size lies between `L - 49,692,672` and `L - 34,557,952`.

## Deliberate choices / not recovered

* The key index is random per run like the original; tests and comparisons pass one explicitly (`--bak-key-index`).
* Only the **PC Browser type** is written. The PC Viewer type is disabled in the original's dialog on the test card and is not implemented.
* Split-part references of the original's list (a later "continuation" part referenced from an earlier one) were never seen;
  the reader refuses them explicitly (`WindowsBackupTests.testSplitPartReferenceExplicitlyRefused`).
* The Mac writer never writes into an existing run folder, never touches the source, writes into a hidden staging folder and
  renames it only after every part was fully written, and re-opens/compares every extent when asked (`--bak-verify`, GUI "照合").
* Backups of the event / history tabs are not validated: no genuine event backup was available (the Mac lists those tabs, see
  `docs/validation-history.md`, but the BAK writer is verified only for the 常時録画 normal-region recordings).

## Tests

* Unit tests (`Tests/PCBrowserCoreTests/WindowsBackupWriterTests.swift`, `WindowsBackupTests.swift`): golden header/table/XOR
  bytes, size splitting with an unlimited chunk count (12-chunk fixture), wrap-cut block pairs, stream mixing and the boundary
  rules, name counter rule (frame-0 serial, overwritten recording start, first block at ordinal 0, the genuine-name table),
  name clash, ring-wrap table order, trailer/header/mirror pairs, header-less first block, set merge, folder resolution,
  cancel/overwrite refusal, XOR on unaligned slices.
* CI smoke (`scripts/ci-smoke.py`): a generated card is written as a BAK run, verified, re-opened as a folder and written again —
  the second run must be byte-identical.
* Genuine-file comparisons are recorded in `docs/validation-bak.md`.
