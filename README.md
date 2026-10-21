# elpet

A native Emacs companion based on [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet). A small built-in GIF pack is bundled with the repository; the complete animation set is a downloadable release asset. No DSH, Electron, Node.js, or network service is required.

## Installation

Requires **graphical Emacs 30.1+ with GIF support**. Keep a local checkout of this repository and add the following to
your Emacs configuration, adjusting the path as needed:

```elisp
(add-to-list 'load-path (expand-file-name "~/github/elpet"))
(require 'elpet)
```

Run `M-x elpet-mode` to toggle the companion. Keep all `elpet*.el` files, `pack.json`, `crops.json`, and `assets/` together in the checkout. The built-in pack loads local assets; nothing is downloaded automatically. For an existing GIF directory, set `elpet-pack-file` to `nil` and configure `elpet-assets-directory`.

## Usage

- The pet docks inside the text area of the bottom-right window in the Emacs frame where it was enabled, avoiding the mode line and minibuffer. It adjusts when you split or resize windows, pauses animation when there is not enough room, and reappears when space becomes available. If child frames cannot be created, it uses a regular side window.
- Status text appears in a rounded speech bubble above the pet, with a continuous outline and tail, a subtle shadow, and colors for dark and light themes. The bubble body stays opaque so text underneath does not interfere with reading. Customize colors with `M-x customize-face RET elpet-bubble RET`. Emacs builds without SVG support use a bordered text bubble.
- Transparent margins shared by every frame of a GIF are trimmed by default, reducing the child frame without changing the character's scale. The idle window narrows from 220 pixels to about 92 pixels. Set `elpet-trim-transparent-margins` to `nil` to show the full canvas. Standard Emacs child frames remain rectangular; builds with the NS transparency patch described below automatically make the surrounding background transparent.
- A weighted random idle action, such as playing with a puzzle or eating, plays about every 10 seconds, avoiding immediate repetition when alternatives exist. The pet dozes off after 60 seconds of inactivity.
- **Click the pet to pet it; double-click to choose another random action.** A right-click menu is also available. Use `M-x elpet-play` to play any animation in the active pack.
- **Drag the pet or its speech bubble with the left mouse button.** It stays where you release it, including after action changes. Movement is limited to Emacs text areas, avoiding the mode line and minibuffer. With split windows, it snaps to the nearest text area large enough to hold it. `M-x elpet-reset-position` returns it to the bottom-right corner. Dragged positions are saved as normalized offsets within a text area and restored when the mode starts again, clamped to the available space. Dragging is unavailable in side-window mode.
- Starting `M-x compile` shows the working animation. Success or failure appears when the last tracked compilation finishes. This also works for tasks started through compilation-mode. Compilations already running when the pet is enabled are not tracked.
- `M-x elpet-history` shows complete messages and status changes. Bubbles grow with their content, up to eight lines by default and further limited by space in the editing window. Text is left-aligned with consistent padding, and English text wraps between words where possible. Short replies shrink back to a compact bubble. Hover over a longer bubble and scroll the mouse wheel to read the rest; a small scrollbar shows your position. Scrolling preserves the bubble size and animation, and gives you another 20 seconds to read the message. Full messages remain in the bounded history. Set `elpet-bubble-max-lines` to adjust the height limit.
- `M-x elpet-hide` toggles visibility while activity events continue to update. Showing the pet restores its current state.
- `M-x elpet-doctor` reports rendering capabilities, active resources, and the last display error.
- `M-x elpet-stop` stops the pet, cancels animation and state timers, removes hooks, and releases its windows and buffer.

The pet does not take keyboard focus by default. In side-window mode, use `SPC` to pet it, `n` for a random action, `a` to select an action, `h` for history, `c` for chat, and `q` to close it. You can also run `M-x elpet-pet` or `M-x elpet-random-action` directly.

```elisp
;; Default width: 220 pixels. Re-enable the mode after changing size or display type.
(setq elpet-width 220
      elpet-margin 16
      elpet-sleep-delay 60
      elpet-follow-compilation t)

;; Use a regular side window if child frames are unavailable.
(setq elpet-display-type 'window)

;; Show still frames and disable periodic action changes.
(setq elpet-reduced-motion t)

;; Disable position restoration, or disable all preference file I/O.
(setq elpet-remember-position nil)
;; (setq elpet-state-file nil)
```

You can also configure options with `M-x customize-group RET elpet RET`. Display preferences are saved in `elpet/state.json` under `user-emacs-directory`; live resources, task state, and message history are not written there. Explicit Custom settings take precedence over saved display defaults.

## Character packs

The repository ships a small built-in pack with one action per state, so the
pet works immediately after installation. The complete animation set is
published as the `elpet-pack-full-v1.tar.gz` asset on the
[releases page](https://github.com/vritser/elpet/releases), not in git history.

To install the full pack:

1. Download the archive from the releases page.
2. Run `M-x elpet-install-pack` and select the archive (or an extracted pack
   directory).
3. The command verifies the official SHA-256, extracts into
   `elpet-pack-install-directory` (default `~/.emacs.d/elpet/packs/`), points
   `elpet-pack-file` at the installed manifest, and restarts `elpet-mode` if it
   is active.

The command only touches a local file; it never downloads anything. A custom
archive whose checksum differs from the official full pack requires explicit
confirmation. For manual installation, extract the archive and set:

```elisp
(setq elpet-pack-file "~/.emacs.d/elpet/packs/elpet-full/pack.json")
```

Pack files are data only. See the [character pack
format](docs/extension-api.md#character-packs) for the manifest schema and the
[asset terms](assets/README.md) for attribution and licensing.

## Optional gptel chat

Install and configure [gptel](https://github.com/karthink/gptel) through your usual Emacs package setup, then run `M-x elpet-chat` or choose **Chat** from the pet's right-click menu. The chat module loads gptel only when requested; animation and compilation feedback work without it. The dedicated chat buffer captures the current `gptel-backend` and `gptel-model` when created and uses gptel's existing authentication configuration. Opening a conversation never sends a request.

Type after `You:` and use these commands:

| Key | Action |
| --- | --- |
| `C-c C-c` or `C-c RET` | Send the draft |
| `C-c C-k` | Stop this reply |
| `C-c C-r` | Retry the retained draft after an error or stop |
| `C-c C-p` | Set this conversation's persona |
| `C-c C-s` | Save completed turns, persona, and the unsent draft as JSON |
| `C-c C-v` | Toggle Markdown markers in formatted chat |

The pet thinks while a reply is pending. Replies stream into the chat buffer, with bubble previews limited to five updates per second. Scroll over the bubble to read longer replies without opening a window; your reading position is preserved as streaming text grows. Click a chat bubble to open the full conversation; clicking the character still pets it, and dragging the bubble still moves it. Background responses never select a window. Non-streaming backends also work.

When [markdown-mode](https://github.com/jrblevin/markdown-mode) is installed, the full conversation uses formatted headings, lists, emphasis, links, and language-aware code highlighting. User and pet messages have separate labels. Markdown markers and link URLs are hidden for reading; `C-c C-v` toggles the markers for inspecting the source. Rendering changes only the display: model context and saved sessions retain the original text. Without markdown-mode, chat falls back to plain text. Bubble text remains compact plain text.

Only one request runs at a time in the pet conversation. Stopping, killing the chat buffer, or stopping the pet cancels its request and invalidates late callbacks. Failed or stopped replies remain visible in the buffer, and their prompts stay editable for retry; incomplete replies are excluded from subsequent model context. The chat buffer survives a pet restart and reconnects when opened or sent again.

Customize `elpet-chat-persona` for new conversations. Changes through `C-c C-p` affect only the current conversation. Chat uses completed conversation turns and the persona as context; tools, attached gptel context, and prompt transforms are disabled for these requests. Reasoning notifications are excluded from replies and bubbles. Ordinary gptel conversations are unaffected.

Use `M-x elpet-chat-open` to restore an explicitly saved JSON conversation. Sessions are not saved automatically. The file contains completed messages, the persona, and the draft; it does not contain credentials, backend settings, or incomplete replies. Restoring uses the current gptel configuration and does not send anything. The adapter was verified against gptel 0.9.9.6 (`e7cebe4`) with simulated transports; no paid model request is part of the tests.

## Integration with other packages

The public function `elpet-set-state` accepts a state and an optional duration in seconds. It does nothing while the mode is disabled:

```elisp
(elpet-set-state 'thinking 30)
(elpet-set-state 'working 60)
(elpet-set-state 'success 10)
(elpet-set-state 'error 10)
```

Supported states are `idle`, `sleeping`, `thinking`, `working`, `waiting`, `success`, `error`, and `happy`. When a temporary state expires, the pet resumes the appropriate compilation or idle state. Other packages can call this interface from hooks. Manual reactions temporarily take precedence, then the display is recomputed from active tasks. Compilation is the built-in activity adapter. Registered sources can submit ordered activity events, messages, and state requests through the [extension API](docs/extension-api.md); removing one source leaves others intact.

## Current scope

Version 0.1 provides one displayed pet, weighted animation playback, click interactions, dragging and position restoration, idle detection, reduced motion, bubble previews and history, compilation feedback, optional gptel chat, and a source-based event interface. Character packs are validated JSON data; missing actions fall back to idle or a static image. The pet lives inside Emacs, with a background matching the theme and a rectangular child frame. Roaming, throwing physics, balance displays, and multiple pets from the browser version are not implemented. The built-in preview GIFs are 220 × 124 pixels at approximately 12 fps; enlarging them reduces sharpness. Terminal Emacs cannot display the pet and reports that a graphical session is required.

## Experimental macOS NS background transparency

On 2026-10-19, the Emacs Plus
[`frame-transparency` patch](https://github.com/d12frosted/homebrew-emacs-plus/tree/master/community/patches/frame-transparency)
was verified with a separately built Emacs 31.1.50 NS version. The child frame background,
transparent GIF pixels, and space around SVG bubbles reveal the parent window's text,
while the character and bubble body remain opaque. This requires neither Canvas nor separate windows for individual image rows.

At startup, the pet detects the NS transparency patch and automatically sets
`alpha-background = 0`, `ns-background-blur = 0`, and
`ns-alpha-elements = (ns-alpha-all)` on its own child frame. These settings are
reapplied when the frame is recreated. Standard NS builds use the trimmed rectangular window;
other editing windows are unaffected.

On macOS, when librsvg's `rsvg-convert` is available, bubbles are converted asynchronously into PNGs at twice the display resolution with full alpha, then cached by text, size, and colors. An SVG fallback is available while conversion runs, so input does not wait for an external process. This prevents the Emacs SVG loader from blending the background color into antialiased edges and shadows. Without the converter, rendering falls back to an SVG mask.

After updating the Lisp source, reload `elpet.el` and enable `M-x elpet-mode`.
Visual transparency does not imply mouse click-through. Hit testing in transparent regions, fullscreen behavior, and multiple displays still need separate verification.

## Development

The current module map, state flow, and lifecycle rules are described in
[architecture](docs/architecture.md). Contribution rules and the definition of
done are in [AGENTS.md](AGENTS.md); [CHANGELOG.md](CHANGELOG.md) records
user-visible changes. Numbered decision records and their rationale live in
[postmortem/](postmortem/), starting from the
[template](postmortem/000-template.md).

## Validation

Run the one-shot gate from the repository root:

```sh
scripts/verify.sh
```

It checks syntax and package headers, byte-compiles every production file with
warnings as errors, runs the full batch suite, verifies a clean load, and scans
for whitespace and tree junk. CI runs the same gate on Emacs 30.1 and 31.1.

The individual steps are also available:

```sh
emacs -Q --batch -l scripts/check-lisp.el
emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile elpet*.el
emacs -Q --batch -L . -l tests/elpet-test.el -f ert-run-tests-batch-and-exit
```

To run the same suite in an isolated graphical Emacs, without `--batch`:

```sh
scripts/run-gui.sh
```

The wrapper passes an absolute path because GUI Emacs does not reliably inherit
the shell's working directory. The runner exits after testing and saves a report
in the system temporary directory. Graphical tests cover animation, bubble edges, long text, theme changes, window fallback, hiding, normalized position restoration, repeated mode toggling, and stale callbacks. Batch mode skips graphical tests. Other operating systems and a real Emacs 30.1 installation still require separate validation.

The regular suite includes mocked chat lifecycle tests and requires no gptel installation. To additionally validate against a real gptel checkout, add gptel and its dependencies to the load path:

```sh
emacs -Q --batch -L . -L /path/to/transient -L /path/to/gptel \
  -l tests/elpet-gptel-test.el -f ert-run-tests-batch-and-exit
```

This exercises gptel's real request builder and buffer-scoped abort API with replaced network transports. It sends no network requests and requires no API key.

`crops.json` stores the visible bounds across all frames of each bundled animation, along with its SHA-256 hash. New or replaced assets without matching metadata use the full canvas to avoid clipping movement. Developers can regenerate the measurements with `python3 tools/generate-crops.py`, which requires ffmpeg and ffprobe. Neither tool is required to run the pet, and the original GIFs are never rewritten. The built-in pack references this file directly. Custom packs may supply their own crop index; missing, invalid, or outdated metadata disables trimming safely. See the [character pack format](docs/extension-api.md#character-packs).

## Attribution and licensing

Original project and artwork: [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet). The Emacs Lisp code uses this repository's MIT license. Animation assets retain the upstream terms: **open-source use is allowed; commercial use is prohibited**. Introductions, showcases, and distributions of derivative works must retain the original author's link. See [LICENSE](LICENSE) for the code license and [assets/README.md](assets/README.md) for asset attribution and usage terms.
