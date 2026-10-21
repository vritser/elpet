# AGENTS.md — elpet development rules

`elpet` is a native Emacs companion. Entry point `elpet.el`; current
module ownership and data flow are in `docs/architecture.md`.

- **Baseline: Emacs 30.1.** Keep `Package-Requires: ((emacs "30.1"))` in every
  production file header. Do not add guards, shims, or fallback branches for
  older releases. A raise must update all headers,
  README, CI, and CHANGELOG in the same change. `string-pixel-width` and
  `natnum` are available directly.
- **Runtime dependencies:** Emacs only. `gptel` and `markdown-mode` are
  optional adapters; the pet, bubbles, compilation feedback, packs, and
  persistence must work when both are absent. Do not add a mandatory package
  or a network service.
- **Assets are data, not code.** Never execute pack contents, never download an
  asset automatically, and keep every pack path inside its manifest directory.
  The repository ships a minimal built-in pack; the full pack is a GitHub
  release asset installed only by the explicit `elpet-install-pack` command.
  Code is MIT; bundled artwork keeps its upstream noncommercial terms.

## Core principles

- **Question every abstraction.** Add a file, layer, or indirection only when
  it solves a current problem. Clear ownership beats speculative structure.
- **Refactors must produce net value.** A gain in simplicity, behavior,
  robustness, or test value is required. Moving code or renaming layers
  without making the system easier to understand is not a refactor.
- **Root out helper stacking.** One-use wrappers and pass-through accessors are
  debt. Fix the missing ownership boundary instead of adding another tier.
- **Delete, don't deprecate.** Remove unused code and dead compatibility
  branches; do not add shims or "removed" tombstones. The one sanctioned seam
  is the renderer's legacy special-variable context, which the tests and the
  view macros rely on.
- **Prefer lightweight Elisp.** Use `let*`, `pcase-let`, plists, and hash
  tables for short-lived state. `cl-defstruct` is reserved for the model
  (`elpet-instance`), the view (`elpet-view`), packs, and the chat
  request, which cross module or callback boundaries.
- **Bound everything that grows.** Event IDs, activities, requests, messages,
  and history have explicit limits. New tables need a removal path.
- **Generation guards are mandatory.** Any asynchronous callback must check
  the instance is alive and the captured generation still matches before
  touching a buffer, frame, process, or shared table. Cleanup must tolerate
  re-entry and repeated calls.
- **Do not steal focus.** The pet is a companion, not an editing target. Keep
  `no-accept-focus` on child frames and avoid selecting windows for background
  updates.

## Verification (run after every change — never skip)

**One-shot gate: `scripts/verify.sh`.** It checks syntax, compiles every
production file with warnings as errors, runs the full batch suite, verifies a
clean load, checks package metadata, and scans for whitespace and tree junk.
Exit 0 is the definition of done; any FAIL is a blocker.

```sh
scripts/verify.sh
```

**CI runs the same gate** on every push and pull request
(`.github/workflows/ci.yml`) on Emacs 30.1 and 31.1. A red run is a
blocker even when the local gate passed.

The manual loop, in order:

1. `emacs -Q --batch -l scripts/check-lisp.el` — read-level syntax and header
   check. Fix diagnostics in order and re-run after every edit; one error can
   mask another.
2. `emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile elpet*.el`
   — warnings are failures; delete the generated `.elc` files afterwards.
3. `emacs -Q --batch -L . -l tests/elpet-test.el -f ert-run-tests-batch-and-exit`
   — the full batch suite. Batch mode skips graphical tests.
4. `emacs -Q --batch -L . -l elpet.el` — must print nothing and exit 0.
5. For a function-level repro, prefer a minimal batch script over a long
   interactive session.

Graphical behavior needs a real window system. Run the same suite in an
isolated GUI Emacs:

```sh
scripts/run-gui.sh
```

The wrapper passes an absolute runner path because GUI Emacs does not reliably
inherit the shell's working directory.

When changing chat, also run the optional real-gptel adapter if a gptel
checkout is available:

```sh
emacs -Q --batch -L . -L /path/to/transient -L /path/to/gptel \
  -l tests/elpet-gptel-test.el -f ert-run-tests-batch-and-exit
```

Never weaken or delete an assertion, skip flag, or timeout just to make the
gate pass. Fix the cause or explain why the test is no longer valid.

## Testing rules

- Batch tests must not need a window system, a live network, an API key, or a
  real gptel installation.
- Use the replaceable `elpet--clock` and explicit random functions instead
  of sleeping. The only accepted sleeps are graphical tests that must wait for
  redisplay or an asynchronous image conversion, and they need a bounded
  deadline.
- Create isolated instances and hash tables in tests; do not depend on the
  developer's real `user-emacs-directory`, frame layout, or theme. Set
  `elpet-state-file` to `nil` in tests that could write preferences.
- Every bug fix gets a regression test that fails before the fix. Prefer a
  narrow test of the pure layer (state, events, packs, persistence) over a
  broad GUI test.
- GUI tests are additive coverage, not a substitute for pure tests.

## Documentation and release hygiene

- Update `README.md` when user-visible behavior, defaults, commands, or
  installation steps change.
- Update `docs/architecture.md` when a module boundary, lifecycle rule, or
  public interface changes.
- Add a `CHANGELOG.md` entry under "Unreleased" for user-visible changes and
  move it to a version heading when releasing.
- Keep `M-x elpet-doctor` accurate: its version string and capability
  report must match the code.
- Do not commit, tag, or publish unless the user asks.

## Postmortems (decision records)

`postmortem/` is the historical layer: numbered, one-page records of decisions
and lessons, starting from [000-template.md](postmortem/000-template.md). Docs
describe the current state; postmortems keep the "why" that would otherwise be
lost in a rename or refactor.

- **Read the relevant records before significant changes.** They are
  constraints and rationale, not proof the code still matches them.
- Write one when: adding or changing a user-visible workflow; choosing between
  non-obvious architectural approaches; abandoning or reverting an approach;
  removing a public option or command; deliberately deferring a known
  limitation. Bug-fix-only changes do not need one.
- Explain **why**, not the code: `Background` / `Decision` / `Why` /
  `Consequence` / `Known limitations`, with files, tests, gate output, or
  commits as evidence. This repository has no commit history yet; cite paths
  and commands until it does.
- They are historical records. Do not rewrite old ones to match current
  behavior; write a new entry and add a short "Superseded by NNN" note at the
  top of the old file.
- Link both ways: a `CHANGELOG.md` entry for a decision carries
  `(rationale: postmortem/NNN)`, and the record cites the code and tests it
  describes.

## Coding conventions

- Every production file starts with `;;;` header, `;; Version:`,
  `;; Package-Requires: ((emacs "30.1"))`, `;; SPDX-License-Identifier: MIT`,
  a `;;; Commentary:`, and a `;;; Code:` section. End with `(provide '...)`
  and `;;; ... ends here`.
- Use `;;;###autoload` only for interactive entry points (`elpet-mode`,
  `elpet-chat`, `elpet-chat-open`, `elpet-install-pack`, and
  `elpet-set-state`).
- Docstrings: complete sentences, capitalized first word, no embedded
  keycodes (use `\\[command]`), and document every argument.
- Keep code ASCII unless a user-facing label or test fixture needs otherwise.
- Prefer `condition-case` around asynchronous process and callback boundaries;
  report failures through `elpet--last-error` / view `last-error` rather
  than a bare `message` in the middle of rendering.
