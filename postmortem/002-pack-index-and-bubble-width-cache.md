# 002 — Pack action index and cached bubble width

## Background

Three hot paths rescanned or re-measured data that changes rarely:

- `elpet--asset` walked the pack catalog and then every state/action list
  on each lookup; `elpet--animation-loop-p` walked every state again; and
  `elpet--action-names` rebuilt completion from both collections.
- `elpet--layout` measured every wrapped bubble line with
  `elpet--text-pixels` to derive `elpet--display-width`;
  `elpet--bubble-svg` did the same for its width, so a redraw measured the
  full transcript twice even when only a few lines were visible.
- `elpet--best-message` copied and sorted the whole message list on each
  call. The tick timer calls it while reducing state, and streaming chat
  refreshes bubbles several times per second.

Bubble text and pack files are effectively immutable during one display
session, so these costs were proportional to data size on every redraw rather
than to what changed.

## Decision

Build the derived structures once and key them to the existing invalidation
boundaries:

- `elpet-load-pack` builds `elpet-pack-index`, a `name → action` hash
  containing every state action and catalog-only action with its `:file`,
  `:loop`, and `:weight`. `elpet--asset`, `elpet--animation-loop-p`,
  and `elpet--action-names` read it.
- `elpet--wrap-text` computes `elpet--bubble-max-width` once when it
  recomputes wrapped lines. The view field is reset on cleanup and reused by
  `elpet--layout`, `elpet--bubble-svg`, and the plain-text fallback
  (which still uses character columns, not pixels).
- `elpet--best-message` selects the highest-priority unexpired message in
  one pass, keeping the newest message on ties.

## Why

The index is the natural place to validate pack definitions once: the loader
already rejects duplicate names and conflicting file/loop definitions, so a
hash cannot disagree with the state lists. Rebuilding it lazily per pack would
add a cache table and a lifetime to invalidate for no gain; a pack is loaded
when the mode starts. Reading the index also makes asset lookup O(1) and keeps
completion consistent with the renderer.

The wrap key already captures everything that changes measured width — text,
`elpet-width`, and the parent frame's font. Caching the maximum at wrap time
adds no new invalidation rule. Measuring only the visible slice was rejected
because the bubble would resize while scrolling; precomputing per-line widths
during wrapping was rejected because the additional view state buys little over
one max scan per text change.

For messages, a single pass avoids allocating and sorting a copy in a path that
runs on a one-second timer. The old code returned a plist from a copied list, so
callers could still mutate the stored message through the returned value; the
new code has the same aliasing semantics. Ties now deterministically prefer the
newest message instead of relying on sort stability.

## Consequence

Asset lookup, loop rules, completion, bubble layout, and message selection all
use cached or single-pass data. The new field is `elpet-pack-index` on the
pack struct and `bubble-max-width` on the view. Two regressions were added:
`elpet-core-pack-index-serves-assets-loops-and-completion` and
`elpet-core-bubble-width-is-cached-by-wrap-key`.

## Known limitations

`elpet--pack-actions` still checks `file-readable-p` on each candidate, so a
deleted asset stops being chosen without a reload. A pack edited on disk needs a
mode restart or a fresh `elpet-load-pack`; there is no file watcher. The
bubble width cache is keyed by text, width, and frame font, not by the
`elpet-bubble` face's font — the measurement uses the frame font, as before.
The plain-text fallback still measures character columns directly; it has no
pixel-width cache.
