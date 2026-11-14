# Destructive operations (format, initialise, delete, password, firmware)

Operations of the original PC Browser 1.9.60.0 that change an original card. This page records what was learned about
them, and what the Mac port does about them. **None of them is implemented; the Mac port never writes to an original
card, to a mounted volume or to a device node.** Nothing on this page is a claim that the operations work.

No value of a real card or image (identifiers, sector numbers, clocks, passwords) appears here, in the code or in the tests.

## Policy (implemented, unit-tested)

* `WriteGuard` (Core) refuses every output that is not a *new* file or folder: existing files are never overwritten,
  nothing under `/dev`, nothing equal to or inside an input (images, backups, mounted cards), symlinks resolved first.
* `DestructiveOperation` lists the seven operations the app will not perform (format, initialise, delete recordings, set /
  remove password, firmware update, write card settings *to an original*) with the reason shown to the user; the menu
  entries of the original that lead to them are kept in the menu inventory with that reason.
* Recording settings can be edited only as a **new copy** of an image (`RecordingSettingsStore`, dialog "記録設定"): the copy is made
  with a read-back SHA-256 check first, four management sectors are rewritten with the format of `settings-format.md`, and the
  edit is refused when the copy does not look like the verified Q-01 layout (identifier, backup sectors, checksum).
* Command files for the card (`CONFIG/…`) are likewise written to copies only (`CardCommandFiles`).

## What was observed for "フォーマット" (menu → dialog chain)

All observations come from the original running under Wine against a **scratch copy** of a card image with a hook that
logged and redirected raw disk access; the original card image was never opened for writing.

1. The original shows a warning that formatting erases the data, then a second confirmation ("本当にフォーマットしてもよろしいですか？")
   and a progress box "フォーマット中".
2. It opens the card's drive and the physical drive for writing, asks for the drive geometry and the volume's disk extents, and
   locks, dismounts and unlocks the volume (Windows `DeviceIoControl` codes for geometry, volume extents, lock, dismount, unlock).
3. On the scratch image it then wrote four things, in this order: the partition table sector (twice, once to clear and once to set
   one FAT16 partition, type 0x06), a FAT16 boot sector (OEM name `MSDOS5.0`, 512 bytes per sector, 16 sectors per cluster, one FAT,
   512 root entries, media descriptor 0xF8, volume label `NO NAME`), and the first FAT sector.
4. Under Wine the rest of the sequence stops with an error (an unimplemented system call), so the writing of the management
   sectors, the clearing of the recording areas and whatever the original does for a particular model were **not observed**.

What this does and does not establish: the file-system part of "フォーマット" is an ordinary FAT16 format with parameters that are
visible above. The model-specific part (management sectors, area table, model initialisation, which areas are cleared) is not
known, so a card formatted by this alone would not be a card the recorder accepts. That is the reason the operation stays refused.

## Not analysed

| Operation | State |
| --- | --- |
| パスワード設定／解除 (dialog 106) | key derivation and stored form unknown; a wrong write could make the card unreadable |
| 録画消去 (dialog 121) | rules for the management area and the circular areas unknown |
| 機種指定初期化 | not reached (see step 4) |
| ファームウェア更新 | update procedure and signatures unknown |
| 他機種の記録設定ダイアログ (131–139) | storage layout not analysed (only Q-01 class, `settings-format.md`) |

A future change that implements any of these needs (a) a documented format derived from the original's own writes on a scratch
copy, (b) a copy-only mode first, and (c) a per-model approval before any original medium is touched.
