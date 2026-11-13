# Validation gaps — what has *not* been verified

This page separates what the Mac port has been shown to do (see `validation-history.md`, `validation-full-port.md`, `validation-bak.md`) from what has **not** been verified. Nothing on this page may be read as "works"; each row names the missing evidence. A row leaves this page only when the evidence exists and is linked from the validation documents.

## Hardware and media

| Area | Status | Missing evidence |
|---|---|---|
| Physical SD card in a reader | not tested | no card reader or physical card is available in the verification environment; all real-card results come from an image of a card |
| Physical camera / recorder | not tested | no device; recorded behaviour of a camera that reads a card written by the Mac port is unknown |
| Writing to an original card or image | **forbidden by design** | the Mac port writes only to copies; original media are never opened for writing |
| Other models than the sample card's model (Q-01) | partly analysed | settings storage and dialog controls were observed on one model only; other models expose more (or other) controls |
| Cards from other firmware versions, damaged cards, wrapped circular recordings | not tested | only the sample card and partial backups of it were available |
| Intel Mac GUI, macOS 14 execution | not tested | unit tests ran on an Intel CI runner (compatibility build); the GUI has not been exercised on Intel hardware or macOS 14 |

## Original-application equivalence

| Area | Status | Missing evidence |
|---|---|---|
| Event list | 5/5 rows identical on the sample card | other cards, other trigger bits (mask bits beyond 0x01/0x02/0x04/0x08/0x10 are not exercised) |
| Journal (常時録画履歴) list | start 517/517, start+duration 514/517 | three duration differences and two extra marker rows are unexplained |
| 360° conversions, NIGHT, optical calibration | implemented independently | pixel-level comparison with the original output has not been done; the original's factory calibration is not reproduced |
| Multi-camera synchronisation | not implemented | physical multi-camera recordings were not available |
| G / gyro units, axes, external inputs | raw values only | calibration and axis conventions are unknown without a device that produces known accelerations |
| Original print layouts | PDF layouts are Mac-original | the original's print preview was not captured for comparison |
| Google Earth rendering of generated KML | launch verified, display not verified | screen capture of the verification VM is black and the accessibility tree exposes no document nodes |
| AVI larger than 4 GiB, destination-full behaviour | not run with real video | needs a card image with enough video and a volume to fill |

## Settings, password and format operations

Tracked in `settings-format.md`. In short: every setting field the Mac port writes was derived from the original's own writes on a scratch copy and is limited to the sample card's model; password semantics, model initialisation, quick/full format, delete and firmware update are analysed or guarded but never executed against an original medium.
