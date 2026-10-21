#!/bin/sh
# SPDX-License-Identifier: MIT
# run-gui.sh --- run the graphical ERT suite in an isolated Emacs.
#
# GUI Emacs does not reliably inherit the shell's working directory, so pass an
# absolute path to the runner instead of the relative path used in batch mode.

set -u
cd "$(dirname "$0")/.." || { echo "run-gui: cannot cd to repository root" >&2; exit 1; }
exec "${EMACS:-emacs}" -Q -l "$(pwd)/tests/run-gui.el"
