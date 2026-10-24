# Extension API

The standalone core uses local Emacs Lisp calls and data-only character packs. It has no network or model dependency. This document describes the implemented 0.1 interfaces.

## Default display and model handles

`M-x elpet-mode` owns one displayed companion. Omitting the optional `pet` argument in API calls targets that instance. APIs never start the display implicitly.

`(elpet-create &optional id)` creates an isolated model handle without a window. A supplied ID must be a unique nonempty string. Pass its handle or ID as `pet`; `(elpet-destroy pet)` invalidates it and releases owned resources. Repeated destruction is harmless. Destroyed handles reject late events even if another instance later uses the same ID. Multiple displayed pets are not exposed in this version.

`(elpet-snapshot &optional pet)` returns detached data containing `:id`, `:generation`, `:revision`, semantic `:state`, `:activities`, `:playback`, `:messages`, and `:history`. An inactive target returns `nil`. The semantic state describes task and manual activity; idle sleep is resolved separately by the display. Modifying a snapshot does not mutate the instance.

## Registering an activity source

```elisp
;; Enable the companion explicitly before attaching an external source.
(elpet-mode 1)

(let* ((pet-id (plist-get (elpet-snapshot) :id))
       (epoch (elpet-register-source "my-build")))
  (elpet-emit
   (list :schema-version 1
         :pet-id pet-id
         :source-id "my-build"
         :source-epoch epoch
         :sequence 0
         :event-id "build-1-start"
         :activity-id "build-1"
         :kind 'started)))
```

`(elpet-register-source id &optional options pet)` accepts:

| Option | Meaning |
| --- | --- |
| `:epoch` | Optional integer or string identifying a connection lifetime. By default, the core assigns an increasing integer for each registration of this source. Capture and reuse the returned value in callbacks. |
| `:kinds` | Permitted event kinds. Defaults to activity lifecycle events. Include `say` or `state` explicitly if needed. |
| `:priority` | Maximum bubble priority and external state-request priority, from 0 to 60; default 40. Manual reactions use a separate priority of 80. |

`manual` and `local` are reserved source IDs. Re-registering a source clears its previous facts and subscriptions to those facts; it does not remove instance-wide event subscribers. Explicit epochs must differ from the previous registration. After reconnecting, callbacks must use the newly returned epoch.

`(elpet-unregister-source id &optional pet)` removes that source's activities, temporary messages, and outstanding state requests. Other sources, including local compilations, continue normally.

## Event contract

`(elpet-emit event &optional pet)` accepts a plist with these required fields:

| Field | Meaning |
| --- | --- |
| `:schema-version` | `1` |
| `:pet-id` | Target ID from the snapshot |
| `:source-id` | Registered source ID |
| `:source-epoch` | Epoch returned when registering the source |
| `:sequence` | Nonnegative integer, increasing within this source and epoch |
| `:event-id` | Nonempty unique string |
| `:kind` | An allowed lifecycle event, `say`, or `state` |

Activity kinds are `started`, `updated`, `waiting`, `finished`, `failed`, and `cancelled`. They require a nonempty `:activity-id`. Optional `:state 'thinking` distinguishes model-like work from ordinary `working`. Use unique activity IDs within an epoch; terminal activities cannot restart. Cancellation does not generate success or failure feedback.

A `say` event requires `:text`; a `state` event requires one of `idle`, `sleeping`, `thinking`, `working`, `waiting`, `success`, `error`, or `happy`. Both accept a positive `:seconds` lifetime, defaulting to 10. Messages can include `:replace-key`.

Set `:baseline t` on the first event after registration to suppress historical completion feedback. Initial snapshots should establish current activities rather than replay completed tasks as new successes.

Results are `(:ok t :reason accepted)`, `(:ok t :reason duplicate)`, or `(:ok nil :reason ...)`, where failure reasons include `inactive`, `invalid`, `stale`, and `stale-epoch`. Duplicate and old events do not replay feedback. Ordering is per source, never compared across sources. Active activities persist until a terminal event or source removal; temporary messages and feedback expire. Deduplication retains the most recent 128 event IDs and closed activity IDs per source, while sequence checks continue to reject older events.

## Messages, history, and playback

Pass `:format 'markdown` in `elpet-say`'s options to render the bubble's supported
Markdown subset. Omit it or use nil for literal text. Formatting only changes the
display copy; messages and history keep the full original source. It works
without markdown-mode, and does not evaluate code or fetch linked resources.
This option applies to direct calls; data-only `say` events remain plain text.

`(elpet-say text &optional options pet)` returns a message ID, or `nil` for an inactive target. Supported options are `:source` (default `"local"`), `:priority` (default 20), positive `:seconds` (default 10), and `:replace-key`. A named external source must permit `say`, and the requested priority must fit its registered limit. Replacement affects messages with the same source and replacement key. Full messages remain in bounded history even when previews wrap or expire. Set `:history nil` for transient streaming previews, then submit the completed message with the default history behavior. An optional `:action` command symbol runs when the bubble is clicked; the character retains its normal click behavior. These two options apply to direct in-process calls, not to data-only `say` events.

`M-x elpet-history` opens complete messages and changed status labels in a separate buffer. `elpet-history-limit` defaults to 100 entries. History lasts for the current instance and is not saved to disk. Redraws do not duplicate status entries.

`(elpet-set-state state &optional seconds)` requests a manual reaction on the displayed pet and returns a playback ID. It is a no-op while the mode is disabled. The duration defaults to `elpet-action-duration`.

`(elpet-play name &optional pet seconds)` requests a named animation and returns a playback ID. Interactively, it offers all readable actions from the current pack. Requests begin as `accepted`, become `playing` only after display is possible, and end as `finished`, `cancelled`, or `failed`. Displayed requests finish when their duration expires or a non-looping action reaches its final frame. Requests that expire before being displayed are cancelled. Hiding or superseding a displayed request cancels it; hiding does not cancel source activities or external tasks.

`(elpet-cancel id &optional pet)` cancels a playback request or removes a temporary message. Repeated calls are harmless. It does not cancel a host's actual task.

State resolution preserves underlying activities while a manual reaction is displayed. Once it ends, the display is recomputed from current facts. Waiting and errors take precedence over ordinary external state requests and active work; work takes precedence over a completed activity's temporary success feedback.

## Subscriptions and diagnostics

`(elpet-subscribe callback &optional pet)` returns an unsubscribe function. Callbacks receive detached event plists for accepted activity events, source removal, messages, cancellation, and playback transitions. Errors in one subscriber do not prevent others from running. Subscribers should do little work and must not recursively emit events indefinitely.

`(elpet-capabilities &optional pet)` reports the active backend, image formats, optional converter, background transparency, and fallback reasons. Mouse click-through is reported as unverified. `M-x elpet-doctor` also shows the running executable, instance generation, source/subscriber counts, timer and converter status, and last display error.

## Character packs

Set `elpet-pack-file` to a JSON manifest and re-enable the mode. The built-in
[pack.json](../pack.json) provides one action per state. The complete animation
catalog is distributed as `elpet-pack-full-v1.tar.gz` on the releases page, not
in git; `M-x elpet-install-pack` installs a downloaded archive or extracted
directory, verifies the official SHA-256, extracts under
`elpet-pack-install-directory`, sets `elpet-pack-file`, and restarts the mode
when active. It never downloads anything. To retain the original
directory-only behavior, set `elpet-pack-file` to `nil` and use
`elpet-assets-directory`. Changing that directory while using the default
manifest also selects the legacy directory behavior.

A minimal pack looks like this:

```json
{
  "schema-version": 1,
  "pack-id": "my-character",
  "author": "Artist name",
  "source": "https://example.com/original-art",
  "license": "Your actual asset usage terms",
  "fallback": "idle.png",
  "states": {
    "idle": [
      {"name": "idle", "file": "idle.gif", "weight": 3, "loop": true},
      {"name": "look", "file": "look.gif", "weight": 1, "loop": true}
    ]
  },
  "animations": [
    {"name": "wave", "file": "wave.gif"}
  ]
}
```

Names use ASCII letters, digits, underscores, and hyphens; `__fallback__` is reserved. Weights are integers from 1 to 10000, defaulting to 1. `loop` defaults to true; false plays a state action once. State keys use the eight supported semantic states. The optional `animations` catalog exposes additional GIFs for manual selection without adding them to random action pools. Each name must identify the same file wherever it appears in the manifest.

All paths must remain inside the manifest directory, including resolved symlinks. Files are local and are never downloaded. Missing state animations fall back to an available idle action, then to the required readable static fallback (`png`, `gif`, `xpm`, or `pbm`). GIF dimensions and frame delays come from the files themselves. Reduced motion uses still frames and disables periodic action changes.

An optional `crops` path points to an index in the existing `crops.json` format: animation names map to `sha256`, `size: [width, height]`, and `box: [left, top, width, height]`. Trimming applies only to valid bounds and matching file hashes. It does not change the original files. Pack author, source, and asset license are required independently of the code's MIT license.
