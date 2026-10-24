#!/bin/sh
# SPDX-License-Identifier: MIT
# verify.sh --- one-shot verification gate for elpet.
#
# Run from the repository root.  Every step is machine-checkable; exit 0 means
# the change meets the definition of done in AGENTS.md, exit 1 means at least
# one step failed.  CI runs this same script on Emacs 30.1 and 31.1.

set -u
cd "$(dirname "$0")/.." || { echo "verify: cannot cd to repository root" >&2; exit 1; }

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/elpet-verify.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT

fail=0
run() {  # run LABEL LOGKEY COMMAND...
  label=$1
  key=$2
  shift 2
  if "$@" >"$tmpdir/$key.log" 2>&1; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    sed 's/^/     /' "$tmpdir/$key.log" | tail -n 80
    fail=1
  fi
}

printf '== check-lisp (syntax and package headers) ==\n'
run 'check-lisp' check emacs -Q --batch -l scripts/check-lisp.el

printf '\n== byte-compile (warnings are failures; artifacts stay out of the tree) ==\n'
if ls elpet*.el >/dev/null 2>&1; then
  run 'byte-compile' compile env ELPET_BYTE_DIR="$tmpdir" emacs -Q --batch -L . \
    --eval '(require (quote bytecomp))' \
    --eval '(setq byte-compile-error-on-warn t)' \
    --eval '(setq byte-compile-dest-file-function
                    (lambda (source)
                      (expand-file-name (concat (file-name-nondirectory source) "c")
                                        (getenv "ELPET_BYTE_DIR"))))' \
    -f batch-byte-compile elpet*.el
else
  printf 'FAIL byte-compile (no production files)\n'
  fail=1
fi

printf '\n== full batch suite ==\n'
run 'batch-tests' tests emacs -Q --batch -L . -l tests/elpet-test.el \
  -f ert-run-tests-batch-and-exit

printf '\n== clean load (must be silent and exit 0) ==\n'
if output=$(emacs -Q --batch -L . -l elpet.el 2>&1); then
  if [ -z "$output" ]; then
    printf 'ok   clean-load\n'
  else
    printf 'FAIL clean-load (Emacs printed output)\n%s\n' "$output"
    fail=1
  fi
else
  printf 'FAIL clean-load (nonzero exit)\n%s\n' "$output"
  fail=1
fi

printf '\n== whitespace check ==\n'
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  check_cmd='git diff --check HEAD'
else
  # Before the first commit, inspect both the index and the worktree.
  check_cmd='git diff --cached --check && git diff --check'
fi
if eval "$check_cmd"; then
  printf 'ok   whitespace\n'
else
  printf 'FAIL whitespace\n'
  fail=1
fi

printf '\n== junk scan (elc, backups, autosaves, locks, .DS_Store) ==\n'
junk=$(find . -path './.git' -prune -o -type f \( \
  -name '*.elc' -o -name '*~' -o -name '*.orig' -o -name '*.rej' \
  -o -name '.#*' -o -name '#*#' -o -name '.DS_Store' \) -print)
if [ -z "$junk" ]; then
  printf 'ok   junk-scan\n'
else
  printf 'FAIL junk in tree:\n%s\n' "$junk"
  fail=1
fi

printf '\n== summary ==\n'
if [ "$fail" -eq 0 ]; then
  printf '==> verify PASS\n'
else
  printf '==> verify FAIL\n'
fi
exit "$fail"
