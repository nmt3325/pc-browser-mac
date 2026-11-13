# PC Browser Mac development contract

- Read `GOAL_BRIEF.md`, `TODO.md`, `docs/feature-parity.md` and relevant format evidence first.
- Use Craft Anything CLI `--deep` on korakuen for original-program evidence; do not assume an unverified field is a channel, G unit, trigger, calibration, or password format.
- Build application artifacts only in GitHub Actions. Run `swift test --jobs 2`, release packaging/signature checks, and `python3 scripts/ci-smoke.py "$APP_BINARY" "$REPORT"` there. Validate that exact downloaded artifact on the dc Mac.
- Never delete, skip, weaken, or narrow tests to make a goal pass. Review the diff and perform an additional adverse-input/QA pass even when tests are green.
- Preserve lazy catalogs, continuous-session grouping and read-only source access. Write exports only to newly created destinations. Raw SD write/erase/format/FW operations require verified formats, model/device binding and explicit per-device confirmation; never run them on a user's original as a test.
- No unrelated refactors, new runtime dependencies, or ADRs. Record targeted documentation for each feature.
- Do not commit real recordings, locations, device settings, disk images, screenshots, credentials or private test outputs. Synthetic tests and non-private evidence references only.
- Keep `TODO.md` current at checkpoints. Distinguish implemented, verified and blocked. Do not call the port complete while any original feature or required validation remains unresolved.
