# 006 - Give bubble text more room without enlarging the pet

## Background

The 180-pixel text limit forced chat replies and Markdown into many short lines.
Increasing `elpet-width` also enlarged the character and blurred its bitmap
artwork. The canvas could only exceed the sprite width when cropping was active.

## Decision

Use a 260-pixel base text limit, scaled by the existing pet-size setting. Let the
canvas grow to fit the bubble independently of sprite cropping. Cap text width
by the current pane's space, including padding and placement margins. Include
that width in cache keys and queue a refresh when window sizes change.

## Why

Long replies need more horizontal space, while short status messages should
remain compact. A fixed larger canvas would waste space and could hide the pet
in a narrow split. Adapting the existing content-sized layout gives wider text
without adding another user option or changing animation scale.

## Consequence

At the default scale, long text can use about 292 pixels including bubble padding;
the sprite remains 220 pixels before optional cropping. `elpet.el` owns both
measurement and window constraints. README documents the changed default.

Core regression tests cover uncropped sprites and rewrapping the same text when
available width changes; both failed before the implementation. The GUI test
splits and restores a real pane and checks reflow, frame fit, focus and animation
reuse. Validation uses `scripts/verify.sh` and `scripts/run-gui.sh`.

## Known limitations

The pet itself is not shrunk to fit an undersized pane; existing placement rules
still apply. Bubble text scales with a customized pet size. Wide tables and full
documents remain better suited to the full conversation buffer.
