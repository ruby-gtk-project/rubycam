---
name: rubycam-photo-prep
description: >
  Downsize and adjust webcam snapshots with ImageMagick BEFORE viewing them.
  Use this every time you are about to look at an image captured by the
  `rubycam` CLI (or any camera still) — to check framing, find a person,
  verify a control change, or judge exposure. Raw frames are 1920x1080+ and
  often near-black or washed out; reading them unprepped wastes tokens and
  hides what the sensor actually caught. Also use when a snapshot "looks
  black/dark/empty" — a levels stretch usually reveals the scene without
  touching the camera. Assess with the prepped copy; deliver the original.
---

# rubycam-photo-prep — make snapshots assessable before you look

Camera stills straight off the sensor are big (1920×1080 and up) and frequently
mis-exposed while you're still dialing the camera in. Viewing them raw costs a
full-resolution image read and regularly shows you a black rectangle that the
data underneath could have explained.

**The rule: never Read a camera image at full size.** Every single look —
first probe shot or final keeper — goes through a downsized (and, as needed,
adjusted) copy first. There is no "just this once" exception.

Use `magick` (ImageMagick 7); if absent, the same arguments work with the v6
`convert` binary.

## Standard prep

Never overwrite the capture — write a prepped sibling and Read that:

```sh
magick shot.jpg -resize '960x>' -auto-gamma -auto-level shot-prepped.jpg
```

- `-resize '960x>'` halves 1080p (quarter the pixels) and the `>` never
  upscales a smaller image.
- `-auto-gamma -auto-level` correct mid-tones then stretch the histogram to
  full range — this is what turns an "all black" frame into a readable scene.

960px wide is plenty to judge framing, find a subject, or read exposure.

## The adjustment toolbox

When the standard prep isn't enough, pick the tool for the symptom. All of
these write a new file — keep the original untouched.

| Symptom | Tool |
| --- | --- |
| Still too dark after prep | `-gamma 2.0` (raise toward 3.0 for near-black) |
| Too bright / washed out | `-gamma 0.6` or `-brightness-contrast -20x10` |
| Flat, low contrast | `-sigmoidal-contrast 5x50%` |
| Murky mid-tones, known-good black point | `-contrast-stretch 1%x1%` |
| Grainy (heavy noise from a dark rescue) | `-statistic median 3x3` |
| Soft, hard to judge focus | `-unsharp 0x2` |
| Strong color cast (e.g. red LED light) | `-colorspace Gray` — assess in mono rather than fighting the tint |
| Oversaturated / colors distracting | `-modulate 100,60` (drops saturation to 60%) |
| Mirrored (text backwards) | `-flop` |
| Upside down (ceiling-mounted) | `-rotate 180` |
| Need fine detail (text, focus check) | crop, don't upsize: `-crop 800x600+1100+400 +repage` |

Chain them after the standard prep in one call, e.g. a dark grainy frame:

```sh
magick shot.jpg -resize '960x>' -auto-gamma -auto-level \
  -gamma 1.5 -statistic median 3x3 shot-prepped.jpg
```

## Comparing shots

To judge a before/after (did the pan/exposure change help?) view both frames
in a single image instead of two full Reads:

```sh
magick shot-a.jpg shot-b.jpg -resize '640x>' +append compare.jpg
```

`+append` joins left/right (`-append` stacks vertically). Label them if the
order matters: add `-label '%f'` before the inputs and use `montage` instead
of `magick`.

## Probe before you stare at black

A one-liner tells you how dark a capture is (0 = black, 1 = white):

```sh
magick identify -format '%[fx:mean]' shot.jpg
```

- **mean < 0.02** — essentially black. The stretch will still recover a grainy
  scene (verified: a 0.006-mean frame revealed the subject after prep), but
  expect heavy noise. If the camera is yours to adjust, also fix the cause via
  the `rubycam` skill: check `auto_exposure` isn't stuck in manual with a tiny
  `exposure_time_absolute`, raise `gain`/`brightness` — and a fully black frame
  with *no* recoverable detail usually means the OBSBOT is in privacy sleep
  (`rubycam-obsbot` skill, `wake`).
- **mean 0.02–0.15** — dark but workable; standard prep is enough.
- **mean > 0.9** — blown out; lower `exposure_time_absolute`/`gain` instead of
  trying to rescue clipped highlights.

## Working style

- **Prep is for your eyes only.** When the user asked for the photo itself,
  deliver the original capture; the resized, auto-leveled copy is an
  assessment aid, not the product.
- **Every look is a prepped look.** Probe shots while hunting with
  pan/tilt/zoom *and* the final keeper — all viewed at 960px. The full-size
  original exists to be delivered, not to be Read; if you need more detail
  than 960px shows, crop a region (still downsized in bytes) rather than
  opening the whole frame.
- **Better: don't look at every probe shot at all.** If Ollama is installed
  (or the user opts in), the `rubycam-vision` skill's Moondream triage
  answers "anything in frame yet?" for free on intermediate frames, saving
  your image reads for keepers.
- **Fix the camera, not just the file.** If every capture needs heavy rescue,
  the exposure controls are wrong — say so and adjust them via the `rubycam`
  skill rather than silently brightening forever.
