# Driving an OBSBOT Tiny 2 from Ruby on Linux: a debugging journey

We set out to "write a Linux driver" for an OBSBOT Tiny 2 webcam, assuming
none existed. That assumption died in the first five minutes, and the project
became: a dependency-free Ruby V4L2 library, a GTK4 viewer, and a port of
OBSBOT's vendor sleep/wake protocol. This is the chronological record of how
each thing was discovered, debugged, and tested — including the experiments
that lied to us.

## Step 1: probe before building

Before writing anything we looked at what the kernel already thought of the
device. There was no `lsusb` on the NixOS host, but sysfs needs no tools:

```
$ cat /sys/class/video4linux/video0/name
OBSBOT Tiny 2: OBSBOT Tiny 2 St
```

Two `/dev/video*` nodes already existed — the camera had enumerated and
something had bound it. Neither `lsusb` nor `v4l2-ctl` was installed, but on
NixOS nothing needs installing — `nix shell` runs tools straight out of
nixpkgs:

```
$ nix shell nixpkgs#usbutils -c lsusb
...
Bus 004 Device 002: ID 3564:fef8 Remo Tech Co., Ltd. OBSBOT Tiny 2
```

and `v4l2-ctl` showed who had claimed it:

```
$ nix shell nixpkgs#v4l-utils -c v4l2-ctl -d /dev/video0 --all
Driver Info:
        Driver name      : uvcvideo
        Card type        : OBSBOT Tiny 2: OBSBOT Tiny 2 St
        Bus info         : usb-0000:08:00.0-1
        ...
Format Video Capture:
        Width/Height      : 1920/1080
        Pixel Format      : 'MJPG' (Motion-JPEG)
```

So the premise was wrong: the Tiny 2 is a standard **UVC** device and the
kernel's built-in driver handles it. `v4l2-ctl --list-formats-ext` listed
MJPG at 3840x2160@30 and 1920x1080@60 plus YUYV modes, and
`--list-ctrls-menus` showed the full control set including the gimbal:

```
$ nix shell nixpkgs#v4l-utils -c v4l2-ctl -d /dev/video0 --list-ctrls-menus
...
pan_absolute  0x009a0908 (int) : min=-468000 max=468000 step=3600 default=0 value=0
tilt_absolute 0x009a0909 (int) : min=-324000 max=324000 step=3600 default=0 value=-295200
zoom_absolute 0x009a090d (int) : min=0 max=100 step=1 default=0 value=0
```

(±468000 and ±324000 are ±130° and ±90° in 1/3600-degree units.)

**Test:** we captured one frame and *looked at the image*:

```
$ nix shell nixpkgs#v4l-utils -c v4l2-ctl -d /dev/video0 \
    --set-fmt-video=width=1920,height=1080,pixelformat=MJPG \
    --stream-mmap --stream-count=1 --stream-to=/tmp/obsbot-test.jpg
$ nix run nixpkgs#file -- /tmp/obsbot-test.jpg
/tmp/obsbot-test.jpg: JPEG image data, JFIF standard 1.01, ... 1920x1080
```

It was a live 1080p photo of the room. That habit — verify by inspecting
actual output, not API return codes — turned out to be the single most
important tool later.

## Step 2: a pure-Ruby V4L2 library

Since the camera speaks plain V4L2, the "driver" became a userspace library
(`Rubycam`). Design constraints: no C extension, no GStreamer. Two mechanisms
cover everything:

1. **`IO#ioctl` with packed strings.** Ruby's `ioctl` accepts a mutable
   string as the argument buffer and the kernel writes results back into it.
   We computed request codes from the kernel's `_IOC` macro
   (`dir | size | type | nr`) and derived struct layouts by hand from
   `<linux/videodev2.h>`, asserting 64-bit sizes (e.g. `v4l2_buffer` is 88
   bytes including alignment padding). A wrong size changes the request code
   and the ioctl fails with `ENOTTY`, so the device itself validates the
   layouts.

2. **`mmap` via Fiddle.** `uvcvideo` does not support `read()` (device caps
   lack `V4L2_CAP_READWRITE`), so streaming requires the mmap dance:
   `REQBUFS` → `QUERYBUF` → `mmap()` through libc → `QBUF`/`STREAMON` →
   `select`/`DQBUF`/`QBUF` loop.

**How it was tested:** control enumeration was validated by diffing our
output against `v4l2-ctl --list-ctrls-menus` — all 23 controls matched, with
identical ranges and values:

```
$ ruby -Ilib -rrubycam -e '
  Rubycam::Device.open("/dev/video0") do |cam|
    puts "driver=#{cam.driver} card=#{cam.card}"
    cam.controls.each_value { |c| puts "  #{c}" }
  end'
driver=uvcvideo card=OBSBOT Tiny 2: OBSBOT Tiny 2 St
  brightness (integer) min=0 max=100 step=1 default=50 value=50
  ...
  pan_absolute (integer) min=-468000 max=468000 step=3600 default=0 value=0
  tilt_absolute (integer) min=-324000 max=324000 step=3600 default=0 value=-295200
  zoom_absolute (integer) min=0 max=100 step=1 default=0 value=0
```

Then a capture test failed: `select()` timed out after 2 s. Debugging step:
strip the test down to `STREAMON` + a bare `IO.select` with an 8-second
timeout:

```
$ ruby -Ilib -rrubycam -e '
  cam = Rubycam::Device.open("/dev/video0")
  cam.start_streaming
  puts IO.select([cam.to_io], nil, nil, 8).inspect'
[[#<File:/dev/video0>], [], []]
```

`select` fired — the stream was fine, the camera just takes several seconds
to deliver its *first* frame (ISP startup). Not a bug; we raised the default
timeout. The throughput test then confirmed full frame rate:

```
$ ruby -Ilib -rrubycam -e '
  Rubycam::Device.open("/dev/video0") do |cam|
    cam.set_format(width: 1920, height: 1080, pixel_format: "MJPG")
    cam.set_fps(30)
    cam.capture_frame   # discard slow first frame
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    frames = 30.times.map { cam.capture_frame }
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    puts "30 frames in #{dt.round(2)}s (#{(30/dt).round(1)} fps)"
  end'
30 frames in 0.96s (31.1 fps)
```

We also exercised the gimbal and watched the hardware physically move:

```
$ ruby -Ilib -rrubycam -e '
  Rubycam::Device.open("/dev/video0") do |cam|
    cam[:zoom_absolute] = 60
    cam[:pan_absolute] = 20 * 3600     # +20 degrees
    sleep 2
    puts "pan now: #{cam[:pan_absolute] / 3600} degrees"
    cam[:pan_absolute] = 0
    cam[:zoom_absolute] = 0
  end'
pan now: 20 degrees
```

## Step 3: the NixOS gem fight (or: Ruby's pkg-config is stricter than pkg-config)

For the GTK4 viewer we used ruby-gnome's `gtk4` gem — just `gem 'gtk4'` in
the Gemfile, built inside a Nix flake dev shell. It failed. Repeatedly, each
time deeper in the dependency stack. The debugging loop was always the same:
read the gem's `gem_make.out` / `mkmf.log`, find the line

```
.pc doesn't exist: <sysprof-capture-4> (PackageConfig::NotFoundError)
```

and ask why a package that *native* `pkg-config` resolves fine was missing.

Root cause: ruby-gnome uses the pure-Ruby `pkg-config` gem, which parses
`.pc` files itself and resolves the **`Requires.private`** chain of
everything it touches. Native `pkg-config` only needs private requires for
static linking, so a dev shell that satisfies a C build does not satisfy the
gem. Every transitive private dependency's `.pc` file must be on
`PKG_CONFIG_PATH`.

The fix had two parts:

- `inputsFrom = [ gtk4 glib cairo pango gdk-pixbuf ]` in the flake dev
  shell, inheriting the GTK stack's own build environments instead of
  enumerating dev libraries by hand;
- a straggler list of deps that are private even to those builds, found one
  `mkmf.log` at a time: `libsysprof-capture` (glib), `expat` (fontconfig),
  `xorg.libXdmcp` (libxcb), `libselinux`/`libsepol` (libmount),
  `libdatrie` (libthai), and libtiff's compression backends.

One failure looked different: the `atk` gem died with only "rake failed,
exit code 1" and no reason in the log. Debugging step: run the gem's
`dependency-check/Rakefile` manually inside the shell and read it. It calls
`PKGConfig.check_version?("atk")` — and the shell confirmed the gap:

```
$ nix develop -c pkg-config --modversion atk
No package 'atk' found
```

Today `atk.pc` ships with **at-spi2-core**, which we had put in
`inputsFrom` — which pulls a package's *dependencies*, not the package
itself. Moving it to `buildInputs` fixed it.

When libtiff produced its second missing `.pc` in a row, reading the file
directly ended the iteration:

```
$ nix develop -c sh -c 'cat $(pkg-config --variable=pcfiledir libtiff-4)/libtiff-4.pc' \
    | grep Requires
Requires.private:  zlib libdeflate libjpeg Lerc liblzma libzstd libwebp
```

After adding that batch:

```
$ nix develop -c bundle install
Bundle complete! 1 Gemfile dependency, 20 gems now installed.
$ nix develop -c bundle exec ruby -e 'require "gtk4"; puts Gtk::Version::STRING'
4.22.4
```

## Step 4: the GTK4 viewer

The app is one file: a `Gtk::Picture` fed by a 16 ms `GLib::Timeout` pump
that polls the device non-blockingly (`select` with timeout 0) and hands
MJPG bytes to `GdkPixbuf::PixbufLoader`; sliders are generated from whatever
controls the library discovers. Verified by launching it and watching live
video with working pan/tilt/zoom sliders.

## Step 5: the privacy-sleep bug, and the experiments that lied

User report: *"if I tilt it all the way down it shuts off — that's a feature
— but then the UI dies and nothing turns it back on."*

The Tiny 2's privacy mode: fold the camera head down and video stops. Our
first "fix" implemented a power switch by writing `tilt_absolute` to its
minimum, on the theory that fully-down equals the privacy position. An early
experiment *seemed* to confirm it:

```
$ ruby -Ilib -rrubycam -e '
  cam = Rubycam::Device.open("/dev/video0")
  cam.set_format(width: 1280, height: 720, pixel_format: "MJPG")
  cam.capture_frame
  cam[:tilt_absolute] = cam.controls[:tilt_absolute].min   # "sleep"
  sleep 3
  cam[:tilt_absolute] = 0                                  # "wake"
  puts "resumed: #{cam.capture_frame.bytesize} bytes"'
resumed: 165056 bytes
```

We shipped that switch. It didn't work. Attempting to reproduce "deep
sleep", a second test appeared to show an unwakeable camera:

```
after tilt=0 write, tilt reads: 0
no frame: Device or resource busy @ finish_narg - /dev/video0 -> still asleep
```

That `EBUSY` was a **confounder**: the GUI app was still running and holding
the stream; V4L2 allows only one streaming owner per device, so of course a
second process's `DQBUF` setup failed. Two of our experiments had been
measuring the test setup, not the camera.

The decisive experiment was the cheap one we should have run first: command
tilt to minimum, wait, and capture frames on the same handle — then *look at
one*:

```
$ ruby -Ilib -rrubycam -e '
  cam = Rubycam::Device.open("/dev/video0")
  cam.set_format(width: 1280, height: 720, pixel_format: "MJPG")
  cam.capture_frame
  cam[:tilt_absolute] = cam.controls[:tilt_absolute].min
  sleep 10
  5.times { f = cam.capture_frame(timeout: 3); puts "frame #{f.bytesize} bytes" }
  File.binwrite("/tmp/asleep.jpg", cam.capture_frame)'
frame 103528 bytes
frame 103379 bytes
frame 102969 bytes
frame 103157 bytes
frame 102924 bytes
```

`/tmp/asleep.jpg` showed live, **level** video of the room — while
`tilt_absolute` read back -324000. Conclusion: **software tilt does not move
the head to the privacy position and does not trigger sleep at all.** The
fold-down gesture is detected in hardware, and once the camera sleeps that
way, standard UVC/V4L2 writes are accepted (they even read back) but do
nothing. That is exactly why no UI control could revive it.

## Step 6: finding the vendor protocol instead of sniffing it

If V4L2 can't wake it but OBSBOT's own software can, the command must travel
over a vendor channel. The USB descriptors showed it in the VideoControl
interface:

```
$ nix shell nixpkgs#usbutils -c lsusb -v -d 3564:fef8
...
EXTENSION_UNIT, bUnitID 2
guidExtensionCode {9a1e7291-6843-4683-6d92-39bc7906ee49}
bNumControls 19
```

Before reaching for Wireshark and a Windows VM, we searched for prior art:
`OBSBOT Tiny 2 Linux UVC extension unit sleep wake`. First result:
**[Tiny4Linux](https://github.com/OpenFoxes/Tiny4Linux)** (OpenFoxes,
EUPL-1.2, Rust) — a controller for exactly this camera, with sleep/wake
support. We cloned it and traced the implementation through the source:

- `src/libs/usbio.rs`: commands go through `uvcvideo`'s raw XU ioctl,
  `UVCIOC_CTRL_QUERY` (`_IOWR('u', 0x21, struct uvc_xu_control_query)` — a
  16-byte struct holding unit, selector, query code, size, and a data
  pointer).
- `src/libs/camera/camera.rs`: sleep commands are `SET_CUR` on
  **unit 0x02, selector 0x02**; status is `GET_CUR` on **unit 0x02,
  selector 0x06**.
- `src/libs/camera/transport.rs`: payloads are padded to **60 bytes** (the
  control's size — XU transfers must match `GET_LEN` exactly).
- `src/libs/camera/command02.rs`: the 36-byte packet layout —
  frame ID `aa 25`, sequence number (2), segment size `0c 00`,
  checksum (2), function group (6), command (6), 16 zero bytes.
- `src/libs/camera/commands/sleep.rs`: the sleep/wake byte values.
  Function group `0a 02 c2 a0 04 00`; wake = seq `a5 00`, checksum `5f ef`,
  command `be 07 00 00 00 00`; sleep = seq `42 00`, checksum `ea 63`,
  command `bf fb 01 00 00 00`. (Sequence numbers and checksums are fixed
  per command in Tiny4Linux — replayed byte-for-byte, they work.)
- `src/libs/camera/status.rs`: in the 60-byte status response, offset
  `0x02` is sleep state (0 awake / 1 asleep), `0x06` is HDR, and the pair
  `0x18`/`0x1c` encodes the AI-tracking mode.

Porting this to Ruby was ~70 lines (`Rubycam::Obsbot`): pack the
`uvc_xu_control_query` struct (`C3xvx2Q` — three bytes, pad, u16 size, pad,
u64 pointer to a Fiddle buffer), replay the packets.

**How it was tested, live against the hardware.** The very first status read
returned `asleep: true` on a camera that was visibly streaming — leftover
state from our earlier tilt games, a reminder that the previous experiments
had polluted the device. `wake!` flipped it, proving the command channel
worked. Then a clean cycle from a fresh state:

```
$ ruby -Ilib -rrubycam -e '
  cam = Rubycam::Device.open("/dev/video0")
  bot = Rubycam::Obsbot.new(cam)
  cam.set_format(width: 1280, height: 720, pixel_format: "MJPG")
  f = cam.capture_frame
  puts "awake, streaming (#{f.bytesize}b), status: #{bot.status.inspect}"
  bot.sleep!; sleep 3
  puts "after sleep!: #{bot.status.inspect}"
  bot.wake!; sleep 3
  puts "after wake!:  #{bot.status.inspect}"
  puts "frame after wake: #{cam.capture_frame(timeout: 10).bytesize} bytes"'
awake, streaming (94916b), status: {asleep: false, hdr: true, ai_mode: :no_tracking}
after sleep!: {asleep: true, hdr: true, ai_mode: :no_tracking}
after wake!:  {asleep: false, hdr: true, ai_mode: :no_tracking}
frame after wake: 97224 bytes
```

Two more observations from the same session:

- A frame captured 3 s after a *software* `sleep!` still showed live video —
  the hard video cutoff belongs to the physical fold gesture only. The wake
  command is the part that matters: it is the only software path out of
  privacy sleep.
- An external process ran `sleep!`/`wake!` while the GTK app was running;
  the app survived and kept streaming afterwards.

## Step 7: making the UI survive the camera's moods

The final power switch sends the vendor commands. Around it:

- a **2-second status poll** keeps the switch synced when the camera is
  folded down or woken by hand (guarded so programmatic switch updates
  don't re-trigger the handler);
- a **5-second watchdog** rebuilds the stream if video should be flowing
  but isn't — deliberately longer than the camera's first-frame latency so
  warmup after a (re)start is never misread as a stall;
- every device interaction in a signal handler or timeout callback is
  rescued, because an exception escaping either kills the GTK main loop —
  which is what the original "the UI dies" report had actually been.

## Takeaways

1. **Probe before building.** Five minutes of sysfs/`v4l2-ctl` reading
   replaced a kernel-driver project with a userspace library.
2. **Verify with output, not API acceptance.** The camera accepted tilt
   writes that did nothing we believed they did; a captured frame settled in
   seconds what state-polling experiments had gotten wrong twice.
3. **Watch for confounders in hardware tests.** Our `EBUSY` "evidence" of a
   dead camera was just a second process holding the stream.
4. **Search for prior art before sniffing USB.** Tiny4Linux had the exact
   byte sequences; reading its source took an hour where a capture-and-diff
   session against Windows software would have taken days. Credit where due.
5. **When a build tool disagrees with its C counterpart, read its source
   model.** Ruby's `pkg-config` gem resolving `Requires.private` explains
   every NixOS failure we hit; each `mkmf.log` was one more link in that
   chain.
