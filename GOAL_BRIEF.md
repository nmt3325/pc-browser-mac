# Goal: native macOS functional parity with PC Browser 1.9.60.0

**Objective:** Trace every user-facing original feature with Craft Anything Deep, implement the macOS counterpart and verify it without regressing the existing viewer.
**Read first:** `AGENTS.md`, `TODO.md`, `docs/feature-parity.md`, format and validation documents; original PE resources and Deep evidence on korakuen.
**Constraints:** GitHub Actions builds only; preserve read-only originals, fast catalogs, session continuity and all existing tests; no private data commits, unrelated refactors, dependencies or unverified source writes.
**Validate:** `swift test --jobs 2` and `bash scripts/build-app.sh` in GitHub Actions, followed by CI CLI smoke and real-media CLI/GUI checks of that same artifact on the dc Mac.
**Document:** Write concise, targeted documentation for each change; update existing documents or add focused `.md` files as needed.
**Checkpoints:** inventory → evidence → implement → CI → native verification → TODO update. Do not delete, skip, weaken or narrow tests to pass.
**Stop when:** every feature and validation gate passes, or when further work needs unavailable hardware/data or a human decision. Leave exact evidence and blockers; never convert a blocker into a success.

This file is durable state, not an assertion that this host provides an automatic persistent `/goal` service. The current host exposes no create/resume-goal tool and no token budget was requested.

Baseline: commit `9b59230faa1db8cef042d771a7a037a9aece4afa`, 0.2.0-beta.2 build 4, 77 passing unit tests. `docs/feature-parity.md` records the known gaps.
