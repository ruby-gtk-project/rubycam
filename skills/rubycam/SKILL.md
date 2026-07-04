---
name: rubycam
description: >
  Control a physical UVC webcam attached to this machine using the repo's
  `rubycam` CLI — the generic V4L2 side that works on any webcam. Use this
  whenever the user wants a physical result from their camera: "pan left /
  point the camera at me", "zoom in", "take a snapshot / photo / still from
  the webcam", "make the webcam brighter / less washed out", "list my cameras",
  "what can this camera adjust", "reset the camera to defaults", "read the
  current zoom". Reach for this even when the user only describes the outcome
  ("grab a still of what the camera sees", "recentre the lens") without naming
  rubycam or a control. Prefer this CLI over hand-writing Ruby. For OBSBOT-only
  features (wake from privacy sleep, AI subject tracking, gimbal presets, HDR,
  exposure modes) use the companion `rubycam-obsbot` skill instead.
---

# rubycam — generic webcam control (V4L2)

This repo ships a scriptable CLI (`rubycam`) that drives a real webcam over the
kernel's V4L2 interface. This skill covers the **generic** commands that work on
any UVC camera: discovering devices, reading and setting controls, aiming the
lens, and capturing stills. When the user wants a physical result from the
camera, drive it through this CLI instead of writing new Ruby — that's slower
and easy to get subtly wrong.

The attached hardware is an OBSBOT Tiny 2. Its *vendor* features (privacy
sleep/wake, AI tracking, presets, HDR, exposure metering) live in the separate
**`rubycam-obsbot`** skill; consult that one when the request is about those.

## Running the CLI

Invoke the `rubycam` command. How you launch it depends on how it's installed —
check once at the start and reuse whichever works:

- **Installed gem** (`gem install rubycam`): the binary is on PATH, so just run
  `rubycam <command>`. Confirm with `rubycam version`.
- **From a checkout** of the rubycam-gtk repo: it isn't on PATH and needs its
  gems, so run it through Bundler from the repo root:
  `bundle exec exe/rubycam <command>`. If that errors on missing gems, run
  `bundle install` (or `bin/setup`), or enter the dev shell with `nix develop`.
  Don't fall back to plain `ruby exe/rubycam` — it can't find `dry-cli`.

The examples below write `rubycam <command>`; prepend `bundle exec exe/` when you
resolved to the checkout form. The first time you run a command, read stderr —
real failures (no camera, permission denied, wrong device) surface there. Once a
command is known-good you can append `2>/dev/null` to hide Bundler's platform
warnings.

## Orient before you act

The camera has real physical state, so **look first, change one thing, then
confirm**. Two commands orient you:

```sh
rubycam devices     # every /dev/video* node with card/bus name
rubycam controls    # each control: type, min, max, step, default, value
```

`controls` is the source of truth for what's adjustable and the legal range —
read it rather than guessing a control name or a value. Controls printed as
`[inactive]` reject writes until their governing mode changes (for example
`white_balance_temperature` stays inactive while `white_balance_automatic` is
on; `exposure_time_absolute` needs auto-exposure switched to manual first, which
is an OBSBOT concern handled in the companion skill or via `set auto_exposure`).

## Commands

| Intent | Command |
| --- | --- |
| List capture devices | `devices` |
| Device identity (driver, card, bus) | `info` |
| List all controls with ranges | `controls` |
| Read one control | `get <control>` |
| Set one control (clamped to range) | `set <control> <int>` |
| Reset every writable control to default | `reset` |
| Capture a JPEG still | `snapshot [path] [--width W] [--height H]` |
| Nod the camera "yes" (gimbal tilt) | `yes` |
| Shake the camera "no" (gimbal pan) | `no` |

`set` clamps to the device's reported range, so an out-of-range value won't
error — it silently lands at the nearest legal value. That's why you confirm
afterward (see Working style).

**Negative values need `--`.** dry-cli parses a leading dash as an option, so
`set pan_absolute -104400` errors. Write:

```sh
rubycam set -- pan_absolute -104400
```

## Aiming, zooming, framing

On this camera the gimbal and zoom are ordinary V4L2 controls you change with
`set`. Read the live range from `controls` first; the values below are typical
for the Tiny 2 but the CLI clamps to whatever the device reports.

- **Pan** — `pan_absolute`, units of **1/3600 of a degree**, stepped by 3600,
  roughly −468000..468000. Positive is right, negative left. Compute
  degrees × 3600 rather than hand-typing big numbers: 10° right → `set pan_absolute 36000`.
- **Tilt** — `tilt_absolute`, same 1/3600° units; positive up, negative down.
- **Zoom** — `zoom_absolute`, 0 (wide) .. 100 (tight).
- **Recentre** the lens with `set pan_absolute 0` then `set tilt_absolute 0`.

Not every webcam has pan/tilt/zoom — if `controls` doesn't list them, the camera
can't move and you should say so rather than trying.

### Centering a subject from a snapshot (verified on the Tiny 2)

The frame behaves like a **mirror** horizontally: a subject on the *left* of
the image is centered by *increasing* `pan_absolute` (and image-right →
decrease). Vertical is not mirrored: subject low in frame → decrease
`tilt_absolute` (negative tilts down). Don't reason it out from camera-eye
geometry — that guess came out backwards in practice; trust this rule, take a
shot, correct.

Magnitude: at zoom 0 the horizontal field of view is ~80°, so a subject at
the frame's edge is ~40° off axis. Estimate
`degrees ≈ (pixel offset from center / half frame width) × 40`, then
`set pan_absolute` in 3600-per-degree units.

Large moves take a few seconds — the gimbal is a motor, not a register write.
A snapshot fired immediately catches motion blur or the *old* framing. Take a
throwaway snapshot first (it both burns the travel time and warms up the
stream), then the shot you'll assess. If a subject "should be in frame but
isn't" after a pan, check tilt before re-panning — being 30° too high looks
identical to being 30° off sideways.

## Image quality

Brightness, contrast, saturation, gain, sharpness, white balance and similar are
all in `controls`, each 0/1..100 or a device-specific range. "Make it brighter"
→ raise `brightness`; if that's already high, also check `gain` and whether the
subject is backlit (`backlight_compensation`). For manual white balance, turn
`white_balance_automatic` off first, then set `white_balance_temperature`.

When the user just wants to undo fiddling, `reset` returns every writable control
to its default in one shot.

### Exposure recipes (verified on the Tiny 2)

**Dark snapshots? Check `auto_exposure` first.** On this camera the menu is
UVC-standard: `1` = manual, `3` = aperture-priority auto. A camera left in
manual (`1`) with a small `exposure_time_absolute` (e.g. 50) produces
near-black frames that look like a sleeping or broken camera.

**Auto exposure does not rescue one-shot snapshots.** AE converges over a
running stream, but `snapshot` opens the stream, grabs a frame, and closes —
setting `auto_exposure 3` and immediately snapshotting returns a frame taken
before AE has adapted (observed: `exposure_time_absolute` still at its old
value after the shot). For deterministic stills, set exposure manually:

```sh
# Dark room, known-good starting point:
rubycam set auto_exposure 1
rubycam set exposure_time_absolute 1250   # range 1..2500, default 330
rubycam set gain 60                       # range 1..64
# Too bright? Halve exposure_time before touching gain (gain adds noise).
```

Back to normal afterwards: `set auto_exposure 3` for live/streaming use, or
`reset` to restore every default. Long exposures at high gain are noisy — the
`rubycam-photo-prep` skill's denoise step covers assessing them.

## Snapshots

`snapshot` grabs a single JPEG frame. The Tiny 2 shoots up to 4K:

```sh
rubycam snapshot /tmp/shot.jpg --width 3840 --height 2160
```

Two things to warn the user about: the **first frame after the stream starts
takes a few seconds** (sensor/ISP warm-up), and a snapshot from a camera in
privacy sleep is black. When a shot matters (or right after waking/moving the
camera), take a **throwaway snapshot first** and assess the second one. If the image comes back dark or frozen, the OBSBOT may
be asleep — that's the `rubycam-obsbot` skill's `wake` command. With no path
argument, `snapshot` writes `snapshot.jpg` in the current directory at
1920×1080.

Before *you* look at a snapshot (to check framing or exposure), prep it per
the **`rubycam-photo-prep`** skill — downsize and auto-level a copy rather
than reading the raw full-size frame.

## Targeting a specific camera

`-d` matches a device path, a `/dev` name, or a substring of the card/bus name:

```sh
rubycam -d /dev/video2 controls
rubycam get zoom_absolute -d 'OBSBOT Tiny 2'
```

Generic commands default to `/dev/video0`. Run `devices` first if that isn't the
right camera. Note some `/dev/video*` nodes are metadata-only (flagged in
`devices` output) and won't capture frames — pick the plain capture node.

## Working style

- **Confirm the effect.** After a `set`, re-read with `get <control>` and report
  the actual new value, not just "done" — the camera clamps and occasionally
  ignores writes, so the number you asked for isn't always what stuck.
- **One physical change at a time** (pan, then tilt, then zoom) so each result is
  visible; batch only safe idempotent reads.
- **Say when the hardware can't do it.** If a control isn't listed, or is
  `[inactive]`, explain why rather than forcing a write that will fail or clamp
  to nothing.
