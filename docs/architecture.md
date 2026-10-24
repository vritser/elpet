# elpet architecture

Status: current implementation. This document describes the code in this
repository.

`elpet` is an in-process Emacs companion. It has no server, network
connection, or mandatory third-party package. Animated GIFs are data; the Lisp
code reads validated character packs and renders one pet in a child frame or a
regular side window.

## Data flow

```text
compilation / local activity ─┐
chat (gptel) ─────────────────┼→ elpet-emit → source ordering → facts
external sources ─────────────┘                                  │
                                                                  ↓
                            commands / manual playback → state arbitration
                                                                  ↓
                                              view snapshot → renderer
```

Sources submit ordered semantic events. The state layer deduplicates them,
keeps per-source and per-activity facts, and reduces those facts to one display
state. A display view reads that state and draws the animation and bubble.
The renderer never parses host protocols and the state layer never creates
frames, timers, or processes.

## Module ownership

| File | Owns | Must not |
| --- | --- | --- |
| `elpet.el` | User commands, `elpet-mode`, the default instance's view, bubble layout and rendering, docking and dragging, preference wiring, diagnostics | Parse host protocols or add another state model |
| `elpet-model.el` | `elpet-instance` struct, instance registry, lifecycle/generation, publish/subscribe, detached copies, test clock | Create windows or timers |
| `elpet-state.el` | Source facts, arbitration and priorities, expiry, playback requests, messages, bounded history, snapshots | Touch a window or a process |
| `elpet-events.el` | Source registration and epochs, event validation, ordering, deduplication, source removal | Require a host package |
| `elpet-assets.el` | Character-pack parsing and validation, weighted action choice, crop metadata | Render or mutate instance state |
| `elpet-pack.el` | Local character-pack archive/directory installation, checksum verification, extraction | Download files or activate the pack without the user's command |
| `elpet-render.el` | `elpet-view` struct and the dynamic view-binding macros | Hold product behavior of its own |
| `elpet-markdown.el` | Pure Markdown-subset conversion to styled bubble display text | Execute code, run modes, fetch resources, or mutate source text |
| `elpet-persist.el` | Versioned JSON display preferences and position normalization | Persist live objects, task facts, or credentials |
| `elpet-compilation.el` | `compile` integration as the built-in activity source | Leak compilation processes into state facts |
| `elpet-chat.el` | Optional gptel conversation, personas, request lifecycle, JSON save/restore | Become a dependency of the standalone pet |
| `tests/elpet-test.el` | Batch test entry point and the original core regressions | Depend on a live network or a GUI in batch mode |
| `tests/elpet-core-test.el` | Model, state, events, packs, persistence contracts | Start a display |
| `tests/elpet-chat-test.el` | Mocked chat lifecycle and Markdown behavior | Require gptel to be installed |
| `tests/elpet-pack-test.el` | Pack directory/archive installation and path safety | Download a remote archive |
| `tests/elpet-gui-test.el` | Child-frame, side-window, drag, and bubble behavior | Run without a graphical session |
| `tests/elpet-gptel-test.el` | Optional checks against a real gptel checkout | Send a network request |

## Instance and display lifecycle

The model can hold several `elpet-instance` values, but the current UI
attaches a view to one default instance. `M-x elpet-mode` creates the
instance, a view, the buffer/frame or side window, the tick timer, and a
subscription. Disabling saves preferences, destroys the instance, and releases
the view.

Every destroy increments `generation`. Asynchronous callbacks (the PNG
converter, chat replies, the tick timer) capture the instance and generation
before scheduling work and re-check both before touching a buffer or frame.
Late results therefore cannot revive a destroyed pet or overwrite newer state.
Cleanup is idempotent and clears references before deleting frames, because
frame deletion hooks can re-enter cleanup.

`elpet-render.el` exposes two macros. `elpet--with-view` binds the
renderer's special variables to one view and writes them back on exit;
`elpet--with-default` reuses an existing binding or enters the default
view. Runtime ownership remains in the view struct; the special variables are
only its dynamically bound working set.

## State model

- Sources register with an epoch and permitted kinds. Events carry
  `schema-version`, `pet-id`, `source-id`, `source-epoch`, `sequence`,
  `event-id`, and `kind`. A source cannot reuse an epoch, replay a sequence, or
  reuse an event ID.
- Activities are keyed by `(source-id, activity-id)` and move through
  `started / updated / waiting / finished / failed / cancelled`. Terminal
  activities are bounded and expire; a terminal activity cannot restart within
  the same epoch.
- Manual playback requests have priority 80 and supersede earlier manual
  requests. External sources are capped at 60, so they cannot take over
  explicit user actions.
- Arbitration prefers manual control, waiting, failure, active work, thinking,
  completion, then idle/sleep. Temporary facts expire; they never force a
  permanent return to idle.
- Messages and history are separate. The bubble shows the highest-priority
  unexpired message; complete text stays in bounded history even when the
  preview scrolls or truncates.
- All tables that can grow with event volume have explicit bounds: seen event
  IDs (128), terminal activities, finished requests, messages, and history.

## Rendering and persistence

A view owns its buffer, frame or window, timer, image, bubble cache, animation
name, and dirty flag. The bubble is measured from the current frame font, wrapped
to a base text width of 260 pixels scaled with `elpet-width`, and capped by the
available pane width. Its canvas can widen independently of the sprite, even
when transparent-margin trimming is disabled. The wrap and render cache keys
include available text width, so resizing or moving between panes reflows text.
Window-size changes queue a refresh without selecting a window.
Model notifications and completed image conversions queue one coalesced refresh
for the next event-loop turn, independently of the one-second state timer. The
refresh timer belongs to the view, checks the captured instance generation and
view identity, and is cancelled on cleanup. Chat keeps its 0.2-second preview
throttle; the renderer does not add another polling delay. Appended text follows
the tail until the reader scrolls up; scrolling back to the bottom resumes it.
When `rsvg-convert` is available on macOS, SVG bubbles are converted to PNGs
asynchronously; the SVG remains visible until the PNG is ready.

Display placement is a normalized offset inside a text area, not a screen
coordinate. Positions are restored only when the user has not customized the
value explicitly, are clamped to the current layout, and are disabled by
`elpet-remember-position` or `elpet-state-file`.

Messages opt in to Markdown with `elpet-say`'s `:format 'markdown`; chat marks
both previews and final replies this way. Raw source remains in model messages,
history, saved chat and the wrap cache key, so completing a delimiter cannot
break append detection or reader scrolling. Only the display copy is parsed.
Wrapping preserves face runs, SVG renders them as escaped text spans, and the
non-SVG fallback uses the same native faces. The small parser is independent of
markdown-mode and deliberately supports a subset, not full CommonMark.

## Chat presentation

`elpet-chat.el` owns the native conversation layout as well as the request
lifecycle. Named faces inherit the current theme; titles and role labels are
presentation, not part of the stored turns or model context. The draft has an
unnumbered YOU margin label anchored at the non-advancing input marker, with no
textual composer heading or shortcut strip. Keybindings remain in the minor-mode
map and its help, not in persistent chrome. Streaming appends
raw reply text at the buffer end without replacing the layout or selecting a
window; only windows already following the end advance with new chunks.
Role labels use zero-length margin overlays anchored at each message's start,
leaving Markdown at the true beginning of its source line. Their endpoints stay
put when streaming text arrives. Rendering removes all previous role overlays
before rebuilding them; killing the buffer also releases them.

Everything before the draft marker carries native read-only properties as well
as the existing change guard. A transcript property category supplies nonsticky
boundary behavior even when Markdown clears direct stickiness properties, so
restored history stays protected and the draft remains editable. Rendering and
stream callbacks explicitly bind `inhibit-read-only` for their own writes.

Chat mode saves and restores the buffer-local layout settings it changes,
including the header, mode line, margins, wrapping, and line-number display.
Markdown remains optional, and the same presentation works over plain text.

## Boundaries and non-goals

- One displayed pet, one optional gptel conversation, one compilation source.
- No DSH/agent integration, voice, roaming, physics, or multi-pet UI yet.
- No automatic remote asset download. The built-in pack contains one action per
  state; the full pack is a GitHub release asset installed by the explicit
  `elpet-install-pack` command (or configured manually). Pack paths must resolve
  inside the manifest directory, including through symlinks.
- The core stays usable without gptel, markdown-mode, SVG, or `rsvg-convert`.
- Emacs 30.1 is the declared baseline; use `string-pixel-width` and `natnum`
  directly and do not add fallbacks for earlier releases.
