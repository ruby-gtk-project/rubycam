---
name: rubycam-vision
description: >
  Analyze rubycam snapshots with local open-source models: find a person and
  compute the exact pan/tilt correction to center them (OpenCV YuNet face
  detector), or ask free-form questions about the scene (Moondream VLM via
  Ollama). Use this when centering/framing a subject — it replaces eyeballing
  offsets from snapshots with one deterministic measurement — and for "what's
  in frame / what is the person doing / is the desk empty" questions. For
  simply LOOKING at a photo yourself use `rubycam-photo-prep`; for exposure
  judgments use that skill's brightness probe (no model needed); for
  continuous "keep me framed" use the OBSBOT's own tracking
  (`rubycam-obsbot`), which beats any external loop. Also consult this skill
  before any ITERATIVE snapshot loop (subject hunting, framing/exposure
  dial-in): its optional Moondream triage mode answers "anything in frame
  yet?" per probe shot for free — offer to set up Ollama if absent.
---

# rubycam-vision — local models for analyzing captures

Two tools, two jobs. Both verified working on this machine.

## Centering a subject: `scripts/find_subject.py`

YuNet face detection → gimbal delta, with the Tiny 2 conventions (mirrored
horizontal, tilt sign, 3600-units-per-degree, ~80° FOV) already baked in. One
run replaces the whole estimate-pan-shoot-reassess loop:

```sh
nix-shell -p "python3.withPackages (p: [p.opencv4])" \
  --run "python3 skills/rubycam-vision/scripts/find_subject.py shot.jpg"
```

Output (real run — subject sat image-right with their head clipped at the top
of frame; both corrections were the right direction):

```
face 1: bbox=(1031,-2,261,230) score=0.79
face 2: bbox=(1018,594,354,456) score=0.77
best face offset: x=+21% y=-79% of half-frame
pan  correction:   -8.4 deg => pan_absolute  += -28800
tilt correction:  +17.8 deg => tilt_absolute += +64800
```

Apply the deltas: `rubycam get pan_absolute`, add, then
`rubycam set -- pan_absolute <sum>` (the `--` matters for negatives). Take a
throwaway shot, then re-run the script to confirm the subject is near center.

Notes:

- First run downloads the ~230KB YuNet ONNX model next to the script and
  builds the nix opencv env — subsequent runs are fast.
- Offsets are frame-relative, so full-size and downsized copies give the same
  deltas. For a *dark* frame, feed the auto-leveled prepped copy
  (`rubycam-photo-prep`) — the detector can't find faces in near-black pixels.
- Pass `--fov <deg>` when zoomed in (80° is zoom 0; FOV shrinks as
  `zoom_absolute` rises).
- It reports the highest-*score* face, not the biggest box — big low-score
  boxes are usually hands or shadows (observed).
- "no faces found" on a frame you suspect contains a person: subject may be
  facing away or out of frame — fall back to Moondream ("is a person
  visible?") or a small pan sweep.

## Scene questions: Moondream via Ollama

Moondream (~2B vision-language model, runs on this machine) answers free-form
questions: "is a person in frame?", "what is on the desk?", "is the room
tidy?". Setup once per boot:

```sh
curl -s localhost:11434 || (ollama serve &>/tmp/ollama.log &)
ollama pull moondream        # one-time, ~1.7GB
```

Query through the HTTP API with a request file — **not** `ollama run` (its
output is full of terminal escape noise) and **not** base64 on the command
line (a full-size frame exceeds the shell's argument limit):

```sh
magick shot.jpg -resize '960x>' /tmp/vlm-in.jpg
ruby -rjson -rbase64 -e 'puts({model:"moondream", prompt:ARGV[0],
  images:[Base64.strict_encode64(File.binread(ARGV[1]))],
  stream:false}.to_json)' \
  "Describe this scene in one sentence." /tmp/vlm-in.jpg > /tmp/vlm-req.json
curl -s localhost:11434/api/generate --data-binary @/tmp/vlm-req.json |
  ruby -rjson -e 'puts JSON.parse(STDIN.read)["response"]'
```

**Feed it a resize-only copy.** Verified gotcha: the auto-leveled/denoised
copies made for your own viewing cause Moondream to return an *empty*
response (`eval_count=1`, immediate stop). Resize alone is safe; if the frame
is too dark for it to see anything, fix the camera exposure (`rubycam` skill)
rather than feeding it a rescued file.

Trust its answers on presence and gist ("person at a desk, hand on chin" —
accurate in testing); don't trust it for precise positions — that's the
detector's job. If a stronger open VLM is ever needed, `qwen2.5vl` /
`qwen3-vl` via the same Ollama API is the upgrade path (bigger download, GPU
recommended).

## Optional: Moondream triage on every intermediate frame

When a task involves *iterating* on snapshots (hunting for a subject, dialing
in framing or exposure), most frames carry one bit of information — "no
person", "still dark". Reading each one with your own vision spends an image
read on that bit; a Moondream query is free and takes ~200ms. The triage
loop:

1. After every probe snapshot, ask Moondream a narrow question ("Is a person
   visible? Where roughly?") on a resize-only copy.
2. Only Read a frame yourself when the answer changes, the shot is a
   candidate keeper, or Moondream's answer seems off.
3. Keepers and judgment calls (framing quality, expressions, "does this look
   right?") are ALWAYS your own eyes on a prepped copy — a 2B model doesn't
   get the last word on the shot the user asked for.

This mode needs Ollama. Check availability with `command -v ollama`. If it's
not installed, **offer it to the user once** — "installing Ollama + the
~1.7GB Moondream model makes repeated camera work cheaper; want it?" — and
respect the answer. Never install it unprompted. Without it, the normal flow
(prep every frame, look yourself) works fine and `find_subject.py` still
covers centering; the loop just costs more image reads.

## Picking the right tool

| Question | Tool |
| --- | --- |
| Where is the person / how do I center them? | `find_subject.py` |
| Is anyone in frame at all? | Moondream, resize-only copy |
| What's happening in the scene? | Moondream |
| Is the shot too dark/bright? | `magick identify` probe (`rubycam-photo-prep`) — no model |
| Keep the subject framed continuously | OBSBOT firmware tracking (`rubycam-obsbot`) |
