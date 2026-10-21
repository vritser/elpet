# 001 — Verification gate and Emacs 30.1 baseline

## Background

`elpet` starts at Emacs 30.1. It had a working batch suite (70 tests) and a
README "Validation" section with two manual commands, but no aggregate gate, no
CI, no contribution rules, and no current module map. Every change relied
on the author remembering to run the byte compiler and the suite. Production
modules had inconsistent headers: only `elpet.el` declared `Version` and
`Package-Requires`; the other eight modules had an SPDX line and no baseline.

## Decision

Adopt the dsh-emacs engineering model, scaled to this package:

- `scripts/check-lisp.el` — read-level syntax and package-header check without
  loading the package or requiring a third-party tool.
- `scripts/verify.sh` — one gate: syntax/headers, strict byte-compile with
  warnings as errors, the full batch suite, a silent clean load, whitespace,
  and tree-junk scan.
- `.github/workflows/ci.yml` — the same gate on Emacs 30.1 and 31.1.
- `AGENTS.md` — module ownership, lifecycle and testing rules, and the
  definition of done; `docs/architecture.md` — the current-state architecture.
- Normalize every production header to `Version`, `Package-Requires:
  ((emacs "30.1"))`, and SPDX.
- State the 30.1 baseline once: use `string-pixel-width` and `natnum` directly
  and do not add compatibility branches for older Emacs releases.

## Why

The gate makes "done" machine-checkable instead of a memory exercise. The CI
matrix covers the declared minimum (30.1) and the current stable release
(31.1); local validation runs on Emacs 31.1.50, so the 30.1 job is the runtime
proof of the baseline. A strict byte-compile is cheap and catches the
free-variable and unknown-function classes that a batch suite can miss;
warnings-as-errors is safe because the baseline is clean.

Requiring `package-lint` or `checkdoc` was rejected: it would add a
network/tooling dependency to a package whose selling point is "Emacs only";
the two checkdoc warnings that existed were fixed directly instead. Keeping
compatibility branches for pre-30 releases was rejected because no supported
release uses them and they would be dead code in every supported configuration.

## Consequence

A change is complete only when `scripts/verify.sh` exits 0. CI repeats the gate
on 30.1 and 31.1. New production files must carry the standard header and pass
`scripts/check-lisp.el`. The README's manual commands remain as individual
steps, and GUI validation uses `scripts/run-gui.sh`.

The batch suite is 70 tests (57 expected, 13 GUI skips); the graphical suite
is 70 tests (68 expected, 2 skips: markdown-mode absent and the built-in
single idle action) on Emacs 31.1.50.
No runtime command, option, or default changed.

## Known limitations

Local validation still runs on Emacs 31.1.50; the 30.1 job has not been
executed from this checkout because the repository has no remote yet. GUI tests
remain manual and are not in CI. The gate runs a byte compiler, not a full
`checkdoc` pass, so docstring style is reviewed rather than enforced. Header
checks in `check-lisp` prove the declaration text, not that the package
actually loads on that Emacs version; the CI matrix is the runtime proof.
