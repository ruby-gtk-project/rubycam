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

OBSBOT vendor commands (sleep/wake, status) go through the camera's UVC
extension unit — the same channel the official OBSBOT software uses
(protocol from the [Tiny4Linux](https://github.com/OpenFoxes/Tiny4Linux)
project):

```ruby
bot = Rubycam::Obsbot.new(cam)
bot.status   # => { asleep: false, hdr: true, ai_mode: :no_tracking }
bot.sleep!   # privacy sleep (gimbal folds down)
bot.wake!    # wakes even after the camera was folded down by hand
```

Notes:

- The camera delivers 4K@30 / 1080p@60 in MJPG; frames are JPEG strings.
- Folding the camera down by hand is privacy sleep; V4L2 keeps working but
  video stops. `Obsbot#wake!` is the only software way back.
- Writing `tilt_absolute` to its minimum does NOT trigger privacy sleep —
  that gesture is hardware-only.
- The first frame after STREAMON takes a few seconds (ISP startup).

## Viewer app

```sh
nix develop            # or let direnv do it (.envrc: use flake)
bundle install
bundle exec ruby app/camera_app.rb
```

Live preview, sliders for gimbal/zoom/image controls, a power switch
(parks the gimbal in privacy sleep) and reset-to-defaults.

## Examples

```sh
ruby examples/snapshot.rb            # capture snapshot.jpg
ruby examples/controls.rb            # list all controls
ruby examples/controls.rb zoom_absolute 50
```

The library itself has no dependencies beyond the Ruby stdlib; only the
GTK viewer needs the dev shell and `bundle install`.
