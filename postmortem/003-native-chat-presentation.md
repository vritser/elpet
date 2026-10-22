# 003 - Compact native chat with on-demand help

## Background

The user asked to improve the chat buffer before adding another integration.
The original transcript had weak visual separation and a long shortcut header.
An initial redesign added separate role headings and a shaded Message bar, but
feedback showed that these spent too much space on labels and repeated keyboard
instructions. This record consolidates that uncommitted design iteration.

## Decision

Keep presentation in `elpet-chat.el`, without another renderer or dependency:

- Use a larger title and theme-inherited faces; retain the body font so code and
  tables keep their alignment.
- Place numbered YOU / PET labels in a nine-column gutter beside each message's
  first line. Mark the editable draft with an unnumbered YOU label.
- Show only identity and request status in the header, and the chat name and
  scroll position in the mode line. Remove the Message bar and persistent hints;
  keep all keybindings discoverable through the existing `describe-mode` help.
- Save and restore the layout settings and existing window-specific margins.
  Keep restored history and completed messages read-only, with an editable draft.

## Why

The conversation should occupy the screen, not instructions the user has already
learned. Gutter labels remove heading rows without making wrapped paragraphs
ambiguous. A literal role prefix would break Markdown at the beginning of a line;
zero-length margin overlays preserve the source and stay anchored when the first
streaming chunk arrives. Reusing them for the draft avoids placeholder text in
model prompts or saved sessions.

Native faces, margins, and mode help solve the current problem. A web renderer,
card framework, hover panel, or configurable hint layer would add ownership and
lifecycle complexity without improving this workflow. The discarded composer
face was removed rather than kept as a compatibility alias.

## Consequence

`elpet-chat.el` owns the presentation and clears old role overlays before every
transcript rebuild. Buffer destruction releases them as well. Streaming still
appends without selecting a window, and only windows following the end advance.
Turns and requests remain plain conversation data; Markdown is optional. Native
read-only properties and the existing change guard protect history. A property
category keeps the draft boundary nonsticky through Markdown refontification.

`README.md`, `docs/architecture.md`, and `CHANGELOG.md` document the final layout
and boundaries. `tests/elpet-chat-test.el` covers label placement and cleanup,
streaming anchors, unchanged context, retained bindings, local-setting restoration,
and restored-history protection. Verification passes the full `scripts/verify.sh`
gate, graphical suite, and optional Markdown/real-gptel tests with simulated
transports. Isolated previews cover light/dark themes and narrow windows.

## Known limitations

The gutter trades some horizontal space for a more compact vertical layout.
New users must consult the README or mode help to learn the send command; the
draft is identified by its missing exchange number and editable cursor. This does
not change the full transcript rebuild at request completion or isolate malformed
Markdown syntax between messages. Colors and fonts remain theme-dependent.
