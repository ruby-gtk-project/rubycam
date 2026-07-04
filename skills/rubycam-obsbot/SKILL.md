---
name: rubycam-obsbot
description: >
  Control the OBSBOT Tiny 2's special vendor features through the repo's
  `rubycam` CLI — the smart-camera stuff a plain webcam can't do. Use this
  whenever the user wants: the camera to follow / track / frame them ("follow
  me while I move", "track my face", "stop following me"), it to wake up or the
  screen is black/frozen ("the camera's asleep", "wake the camera", "why is it
  dark"), privacy sleep ("fold the camera down", "put the camera to sleep"),
  gimbal presets ("go to preset 2", "jump to my saved position"), HDR on/off,
  auto-exposure metering modes (face / global / manual), tracking speed
  (standard vs sport), or checking the OBSBOT status block. Reach for this even
  when the user only describes the behaviour ("look at the whiteboard", "keep me
  centred", "grab a still but it's black") without naming OBSBOT or rubycam. For
  plain webcam controls — pan/tilt/zoom, brightness, snapshots, reset — use the
  companion `rubycam` skill instead.
---

# rubycam-obsbot — OBSBOT Tiny 2 vendor features

The camera on this machine is an **OBSBOT Tiny 2**, an AI PTZ webcam. Beyond the
generic V4L2 controls (covered by the `rubycam` skill) it has vendor-only
features reached through its UVC extension unit — the same private channel the
official OBSBOT app uses. This skill drives those: privacy sleep/wake, AI subject
tracking, tracking speed, gimbal presets, HDR, and exposure metering.

These commands find the camera by name automatically, so you rarely need `-d`.

## Running the CLI

Invoke the `rubycam` command however it's installed (check once, then reuse):

- **Installed gem** (`gem install rubycam`): on PATH — run `rubycam <command>`.
- **From a checkout** of the rubycam-gtk repo: run it through Bundler from the
  repo root — `bundle exec exe/rubycam <command>`. If that errors on missing
  gems, run `bundle install` / `bin/setup` or enter `nix develop`.

The examples below write `rubycam <command>`; prepend `bundle exec exe/` for the
checkout form. Read stderr on the first run (real failures — no camera,
permission denied — land there); append `2>/dev/null` afterward to hide
Bundler's platform warnings. Add `--debug` to any OBSBOT command to log the raw
extension-unit traffic to stderr when something misbehaves.

## Always check status first

Every OBSBOT session should start by reading the status block — it tells you the
one thing most likely to make an action silently fail (the camera being asleep):

```sh
rubycam status
# asleep:          false
# hdr:             true
# ai_mode:         no_tracking
# tracking_speed:  standard
```

## The privacy-sleep gotcha (the #1 cause of "nothing happens")

Folding the camera down by hand — or `rubycam sleep` — puts it in **privacy
sleep**: the gimbal folds flat, video stops, but V4L2 keeps answering so
controls and snapshots appear to "work" while nothing visible happens. If the
user says the camera is dark, frozen, black, or "not doing anything," check
`status` for `asleep: true` and wake it:

```sh
rubycam wake     # the ONLY software way back, even after a hand-fold
rubycam sleep    # privacy sleep on demand (gimbal folds down)
```

Any tracking / preset / framing request on a sleeping camera should `wake` it
first, or the action does nothing useful. (Writing V4L2 `tilt_absolute` to its
minimum does *not* fold the camera — that gesture is hardware-only.)

## AI subject tracking

The Tiny 2 can motor its gimbal to keep a subject framed. Set a mode with:

```sh
rubycam track <mode>
```

Modes: `no_tracking`, `normal_tracking`, `upper_body`, `close_up`, `headless`,
`lower_body`, `desk_mode`, `whiteboard`, `hand`, `group`.

Map intent to mode:

| User says | Mode |
| --- | --- |
| "follow me" / "keep me in frame" | `normal_tracking` |
| "follow me, tighter crop" / "head and shoulders" | `upper_body` |
| "zoom in on my face" | `close_up` |
| "track me but hide the OBSBOT overlay/gimbal UI" | `headless` |
| "point at the whiteboard" | `whiteboard` |
| "overhead / desk view of my hands or paper" | `desk_mode` |
| "follow my hand / gestures" | `hand` |
| "frame the whole group / everyone" | `group` |
| "stop following me" / "hold still" | `no_tracking` |

Tracking responsiveness — how aggressively the gimbal chases the subject:

```sh
rubycam speed standard   # smooth (default)
rubycam speed sport      # fast/snappy
```

## Gimbal presets

Three stored gimbal positions, numbered **1–3** on the CLI. Jumping to a preset
switches tracking **off** first (a moving gimbal and a fixed target conflict):

```sh
rubycam preset 2
```

If the user wants to *save* a position rather than recall one, note that the CLI
only recalls presets — saving is done on the camera/app — and offer to aim the
gimbal manually instead via the `rubycam` skill's `pan_absolute`/`tilt_absolute`.

## HDR and exposure

```sh
rubycam hdr on            # or: hdr off
rubycam exposure face     # meter for the subject's face
rubycam exposure global   # meter the whole frame
rubycam exposure manual   # hand over to manual exposure controls
```

`exposure face` is the usual pick for a person on camera in mixed light;
`global` suits an evenly lit scene; `manual` lets you then drive
`exposure_time_absolute` via the generic `rubycam` skill.

## Working style

- **Confirm by re-reading `status`.** After a mode change, run `status` again and
  report the actual state — don't just say "done."
- **Expect firmware lag.** On newer Tiny 2 firmware the status block can lag a
  mode change by a few seconds, and it reports tracking speed at a shifted byte
  (both handled by the CLI). If a just-set mode doesn't appear, wait and re-read
  **once** rather than assuming failure or spamming the command.
- **Wake before acting** whenever `status` shows `asleep: true` and the request
  needs live video or gimbal motion.
- **One physical change at a time** so each result is observable.

## Raw extension-unit access (escalate only when needed)

For behaviour no named command covers, there's direct access to the vendor
protocol:

```sh
rubycam xu dump [selector]        # hex-dump a 60-byte state block (default 0x06)
rubycam xu send '16 02 02 00' --selector=0x06   # raw write
```

These are debugging tools — reach for them only when a named command genuinely
can't express what the user wants, and explain what you're sending before you
send it. `TINY4LINUX_FEATURES.md` in the repo root maps the vendor protocol and
is the reference for decoding dumps or composing raw commands.
