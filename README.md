# rubycam

Pure-Ruby V4L2 webcam library plus a GTK4 viewer, built against an OBSBOT
Tiny 2. No C extension and no GStreamer: controls go through `ioctl` and
frames come from memory-mapped kernel buffers via Fiddle.

The OBSBOT is a standard UVC device, so the kernel's `uvcvideo` driver
already handles it — this library talks V4L2 and works with any UVC webcam.

## Library

```ruby
require 'rubycam'

Rubycam::Device.open('/dev/video0') do |cam|
  cam.controls.each_value { |c| puts c }   # discover controls
  cam[:zoom_absolute] = 50                 # get/set by symbol
  cam[:pan_absolute] = 20 * 3600           # gimbal units: 1/3600 degree

  cam.set_format(width: 1920, height: 1080, pixel_format: 'MJPG')
  cam.set_fps(30)
  File.binwrite('frame.jpg', cam.capture_frame)  # blocking
  cam.poll_frame                                 # non-blocking, nil if not ready
end
```

OBSBOT vendor commands go through the camera's UVC extension unit — the
same channel the official OBSBOT software uses (protocol from the
[Tiny4Linux](https://github.com/OpenFoxes/Tiny4Linux) project; see
`TINY4LINUX_FEATURES.md` for the full feature map):

```ruby
cam = Rubycam::Device.find('OBSBOT Tiny 2')  # path, /dev name or card/bus hint
bot = Rubycam::Obsbot.new(cam)
bot.status   # => { asleep: false, hdr: true, ai_mode: :no_tracking,
             #      tracking_speed: :standard }
bot.sleep!   # privacy sleep (gimbal folds down)
bot.wake!    # wakes even after the camera was folded down by hand

bot.ai_mode = :normal_tracking  # :no_tracking :upper_body :close_up :headless
                                # :lower_body :desk_mode :whiteboard :hand :group
bot.tracking_speed = :sport     # or :standard
bot.goto_preset(0)              # stored gimbal positions 0..2
bot.hdr = true
bot.exposure_mode = :face       # :manual, :global or :face

bot.debug = true                # log raw traffic to stderr
bot.send_hex('16 02 00 00')     # raw command to the extension unit
bot.dump                        # current status block as hex
```

Notes:

- The camera delivers 4K@30 / 1080p@60 in MJPG; frames are JPEG strings.
- Folding the camera down by hand is privacy sleep; V4L2 keeps working but
  video stops. `Obsbot#wake!` is the only software way back.
- Writing `tilt_absolute` to its minimum does NOT trigger privacy sleep —
  that gesture is hardware-only.
- The first frame after STREAMON takes a few seconds (ISP startup).
- On newer Tiny 2 firmware the status block lags mode changes by seconds
  and reports tracking speed at byte 0x24 instead of 0x21 (both handled).

## Viewer app

```sh
nix develop            # or let direnv do it (.envrc: use flake)
bundle install
bin/rubycam            # or just `rubycam` with direnv (bin/ is on PATH)

bin/rubycam /dev/video2        # explicit device
bin/rubycam 'OBSBOT Tiny 2'    # find by name
```

Live preview, sliders for gimbal/zoom/image controls, and an OBSBOT panel
with power switch, live status, AI tracking modes, tracking speed, preset
positions, HDR, exposure modes and a raw-hex debug console. The ⤢ button
toggles a compact widget mode (panel only); if the camera disappears the
app keeps polling and reconnects when it returns.

## Examples

```sh
ruby examples/snapshot.rb            # capture snapshot.jpg
ruby examples/controls.rb            # list all controls
ruby examples/controls.rb zoom_absolute 50
```

The library itself has no dependencies beyond the Ruby stdlib; only the
GTK viewer needs the dev shell and `bundle install`.
