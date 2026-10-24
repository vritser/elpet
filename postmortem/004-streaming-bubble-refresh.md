# 004 - Streaming bubbles follow content updates

## Background

Chat published previews every 0.2 seconds, but the display subscription only
marked the view dirty. The one-second state timer delayed actual redraws. Once
the bubble filled its visible lines, `elpet--wrap-text` kept offset zero, so
later chunks appeared below the viewport and the reply looked frozen.

## Decision

Keep chat's preview throttle. In `elpet.el`, coalesce model notifications and
PNG conversion completions into one view-owned, zero-delay refresh timer.
Keep the one-second heartbeat for expiry, idle state and animation selection.
Follow appended text unless the reader scrolls up; resume at the bottom.

## Why

Refreshing after publication preserves the model/view boundary and avoids
reentrant rendering inside a model mutation. A pending timer combines bursts
without increasing idle polling or doing expensive layout for every token.
Explicit reader intent distinguishes a live preview from reading older lines.
New unrelated messages still begin at the top, and completed replies keep the
same viewport. No additional chat transport or animation loop is needed.

## Consequence

`elpet-render.el` owns the refresh timer and following flag alongside the other
view resources. Cleanup cancels the timer, and callbacks check instance
liveness, generation, view identity and timer ownership before touching it.
README and architecture describe the rendering and scrolling behavior.

`tests/elpet-core-test.el` covers coalescing, stale callbacks, following and
reader scrolling. The new regressions fail before the implementation.
`tests/elpet-gui-test.el` drives chat preview and refresh timers with the
heartbeat disabled, checking intermediate text, focus, image reuse, final
history and shutdown. Validation uses `scripts/verify.sh` and
`scripts/run-gui.sh`.

## Known limitations

The backend must deliver incremental text for a streaming preview. Emacs event
loop work and image conversion still affect visible latency; this does not
simulate streaming for a backend that returns one completed response.
