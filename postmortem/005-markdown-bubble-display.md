# 005 - Markdown belongs in the bubble display copy

## Background

The full chat optionally used markdown-mode, but bubbles passed raw model text
to SVG. Even with streaming refresh fixed, users saw emphasis markers, link
destinations and code fences as ordinary text. Installing markdown-mode did not
change that renderer (`elpet.el` and `elpet-chat.el`).

## Decision

Add a pure, dependency-free Markdown subset in `elpet-markdown.el`. Chat opts in
through message metadata, `:format 'markdown`. Parse only when the wrap cache
changes, retain styled runs during wrapping, and render them as SVG spans or
native text faces. Keep raw text in messages, history, chat saves and cache keys.

## Why

A small bubble needs readable headings, emphasis, code and labels, not a browser
or a second full document editor. Reusing markdown-mode fontification would make
bubble appearance depend on an optional package and its mode/fontification hooks.
Keeping conversion pure also prevents code evaluation and remote image fetches.
Explicit format metadata avoids reinterpreting compilation messages or filenames.

Preserving the raw cache key is necessary for streaming: completing a delimiter
can change earlier display characters without changing the source's append-only
relationship. Unclosed inline markup stays literal; fenced code stays literal
inside its block even before the closing fence arrives.

## Consequence

README and `docs/extension-api.md` describe the supported subset and opt-in API.
`docs/architecture.md` assigns parsing to the new module and layout to the view.
The verification script compiles `elpet*.el` so the new module and future modules
cannot accidentally escape warnings-as-errors checks.

Core tests cover source preservation, incomplete markup, code, format changes,
style-preserving wrapping, SVG escaping and the text fallback. Chat and GUI tests
cover streaming metadata, final history, style updates, focus and image reuse.
Validation uses `scripts/verify.sh`, `scripts/run-gui.sh` and the optional real
gptel/markdown-mode suite with simulated transports.

## Known limitations

This is not full CommonMark: tables, HTML, reference links, complex nested link
destinations and multiline inline constructs remain outside the supported subset.
Images show their labels, and links open the conversation through the existing
bubble click action. Code has monospace styling without language highlighting.
The full conversation remains the place for richer document presentation.
