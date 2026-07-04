# Tiny4Linux feature checklist

Feature inventory of [Tiny4Linux](https://github.com/OpenFoxes/Tiny4Linux)
(Rust controller for the OBSBOT Tiny 2), tracked against Rubycam.
Boxes are checked as features land in Rubycam.

## Library (`tiny4linux` crate → `lib/rubycam/obsbot.rb`)

- [x] Open camera by hint: exact path, `/dev/<name>`, or scan `/dev/video*`
      matching card / bus info, skipping metadata-capture nodes
- [x] Device info (card, bus)
- [x] Sleep / wake commands (command02 packets, selector 0x02)
- [x] Get status: sleep state (byte 0x02)
- [x] Get status: AI/tracking mode (bytes 0x18 + 0x1c, 10 modes + unknown)
- [x] Get status: HDR on/off (byte 0x06)
- [x] Get status: tracking speed (byte 0x21: 0=standard, 2=sport)
- [x] Set AI mode — 10 modes (selector 0x06, `16 02 m n`)
- [x] Set tracking speed — standard / sport (command02, selector 0x02)
- [x] Goto preset position 1–3 (command02 with float appendix, selector 0x02;
      invalid preset raises)
- [x] Set HDR mode on/off (selector 0x06, `01 01 xx`)
- [x] Set exposure mode — manual / global / face (two-stage: command02
      mode-type packet on 0x02, then `03 01 xx` on 0x06 for auto modes)
- [x] command02 packet builder (frame id `aa 25`, sequence nr, segment size
      `0c 00`, checksum, function group, command, 16-byte appendix)
- [x] Send raw command bytes to unit 2, selector 0x02 or 0x06
- [x] Hex dump of current 0x06 and 0x02 state
- [x] Debug logging toggle (log sent commands / raw status)

## GUI (`t4l-gui` → `app/camera_app.rb`)

- [x] Sleep/wake control with state shown (icon + label follow camera state)
- [x] Current-status panel: sleep mode, AI mode, tracking speed, HDR, version
- [x] Preset position buttons 1–3 (tracking switched off before moving)
- [x] Tracking mode selector — all 10 AI modes, active mode highlighted
- [x] Tracking speed selector — standard / sport, active speed highlighted
- [x] HDR toggle button
- [x] Exposure mode buttons — manual / global / face
- [x] Dashboard ⇄ Widget (compact) window modes with toggle button
- [x] Periodic camera status poll; UI follows out-of-band changes
- [x] Camera hotplug: "no camera" message and automatic reconnect
- [x] Debug area: toggle debugging, send raw hex to 0x06 / 0x02,
      hex-dump 0x06 / 0x02
- [ ] i18n (7 locales) — skipped: English only, like the rest of Rubycam

## CLI (`t4l` → `bin/rubycamctl`, dry-cli)

- [x] OBSBOT commands: status, wake/sleep, track, speed, preset, hdr, exposure
- [x] Raw extension-unit access: `xu dump`, `xu send` (with `--debug` logging)
- [x] V4L2 commands (any UVC camera): devices, info, controls, get/set/reset
- [x] Snapshot to JPEG with format negotiation

## Rubycam extras (not in Tiny4Linux)

- Live video preview (pure-Ruby V4L2 MJPG streaming)
- Generic V4L2 control sliders (pan/tilt/zoom/brightness/…) + reset
- Stream watchdog (rebuilds stalled stream after privacy sleep)

## Out of scope

- AUR packaging / desktop files / OBSBOT theme assets

## Firmware notes (verified on real hardware, 2026-07)

Tested against an actual OBSBOT Tiny 2 running newer firmware than the
Tiny4Linux captures:

- All set commands (sleep/wake, AI mode, speed, preset, HDR, exposure)
  work byte-for-byte as Tiny4Linux sends them — AI tracking physically
  confirmed.
- The 0x06 status block is **eventually consistent**: mode changes can take
  seconds to appear (the GUI highlights optimistically and re-syncs on poll).
- Tracking speed is reported at byte 0x24, not 0x21 (which reads a constant
  3 on this firmware); `Obsbot#status` checks both.
- Concurrent readers (two processes polling the extension unit) scramble
  status reads — avoid running two control apps at once.
