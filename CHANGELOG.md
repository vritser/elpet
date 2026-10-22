# Changelog

All notable user-visible changes to `elpet`. The project follows the
version declared in `elpet.el`; unreleased work stays under "Unreleased"
until a release changes the header, README, and this file together.

## Unreleased

### Breaking changes

- The minimum is **Emacs 30.1**; CI covers 30.1 and 31.1.

### Added

- `scripts/verify.sh`, the one-shot verification gate: syntax and package
  header checks, strict byte-compilation, the full batch suite, a silent clean
  load, whitespace checks, and tree-junk detection.
  (rationale: postmortem/001)
- `scripts/check-lisp.el`, a dependency-free reader-level syntax and header
  checker. (rationale: postmortem/001)
- CI on Emacs 30.1 and 31.1 (`.github/workflows/ci.yml`).
  (rationale: postmortem/001)
- `scripts/run-gui.sh`, a graphical-suite wrapper that passes an absolute
  runner path.
- `elpet-pack.el` and `M-x elpet-install-pack` for installing a downloaded
  character-pack archive or directory, with official SHA-256 verification and
  path-safe extraction.
- `AGENTS.md` with module ownership, lifecycle invariants, testing rules, and
  the definition of done. (rationale: postmortem/001)
- `docs/architecture.md` describing the current implementation.
  (rationale: postmortem/001)
- `postmortem/` decision records, starting with a template and entries 001–002.
- A full character-pack release asset (`elpet-pack-full-v1.tar.gz`) containing
  every bundled animation; the repository itself ships only a small built-in
  pack.
- Regression tests for the pack action index, cached bubble width, the
  pixel/column measurement branches, and pack installation.

### Changed

- Pet chat now uses a theme-aware title, numbered YOU / PET labels beside each
  message's first line, and an unnumbered YOU label for the editable draft. The
  header and mode line show status and position without repeated keyboard hints;
  all shortcuts remain available through mode help. Previous buffer-local layout
  settings and window-specific margins are restored when chat mode is disabled.
  Markdown source, model prompts, and saved conversation data are unchanged.
  (rationale: postmortem/003)

- Character packs now build a single action index at load time. Asset lookup,
  loop rules, and completion no longer rescan the nested state lists on every
  redraw. (rationale: postmortem/002)
- Wrapped bubble text caches its measured maximum width per wrap key, so
  redraws and scrolls do not re-measure every line.
  (rationale: postmortem/002)
- Message selection is a single pass instead of sorting a copy of the message
  list on every tick. (rationale: postmortem/002)
- The built-in character pack is now one action per state (about 4.5 MB) instead
  of the full animation set; install the full pack from the release asset when
  more variety is wanted.
- `elpet--text-pixels` uses `string-pixel-width` directly, and
  `elpet-width` / `elpet-margin` use the standard `natnum` Custom type.
- All production files declare `Version` and
  `Package-Requires: ((emacs "30.1"))` in their headers.
  (rationale: postmortem/001)
- `M-x elpet-doctor` reads `elpet-version` instead of a duplicated
  literal.

### Fixed

- Restored chat history and completed messages now carry native read-only
  properties, in addition to the change guard. Markdown refontification does
  not spread protection into the editable draft.

- Chat command documentation now uses `\\[command]` references instead of
  embedded keycodes.
- The graphical runner now resolves its own path absolutely, and
  `scripts/run-gui.sh` supplies an absolute path. Loading
  `tests/run-gui.el` relatively could make GUI Emacs hang because the process
  did not inherit the shell's working directory.
