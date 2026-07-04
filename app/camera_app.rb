#!/usr/bin/env ruby
# Live OBSBOT viewer: video preview, gimbal/zoom/image sliders, plus the
# full Tiny4Linux control set (tracking, presets, speed, HDR, exposure,
# debug console) in the OBSBOT panel.
# Run inside the dev shell: bundle exec ruby app/camera_app.rb [device]
require 'gtk4'
require_relative '../lib/rubycam'
require_relative 'obsbot_panel'

class CameraApp
  FRAME_INTERVAL_MS = 16
  SLIDER_KEYS = %i[pan_absolute tilt_absolute zoom_absolute
                   brightness contrast saturation sharpness].freeze
  FULL_SIZE = [1380, 640].freeze
  COMPACT_SIZE = [340, 640].freeze

  def initialize(device_path)
    @device_path = device_path
    @awake = true
  end

  def build
    app.tap do
      app.signal_connect('activate') do
        app.add_window(window)

        window.tap do |win|
          win.title = begin
            device.card
          rescue SystemCallError
            'Rubycam (no camera)'
          end
          win.set_default_size(*FULL_SIZE)
          win.child = layout

          win.signal_connect('close-request') do
            GLib::Source.remove(@pump) if @pump
            close_device
            false
          end
        end

        layout.tap do |l|
          l.append(picture)
          l.append(sidebar)
          l.append(panel.build)

          sidebar.tap do |side|
            sliders.each_value { |s| side.append(s) }
            side.append(reset_button)
            @sliders_in_sidebar = !sliders.empty?

            reset_button.tap do |btn|
              btn.signal_connect('clicked') { reset_controls }
            end
          end
        end

        start_frame_pump
        start_status_sync
        window.present
      end
    end
  end

  # Accepts a device path, a /dev name, or a card/bus substring
  # (e.g. 'OBSBOT Tiny 2').
  def device
    @device ||= (Rubycam::Device.find(@device_path) or
                 raise Errno::ENOENT, @device_path).tap do |cam|
      cam.set_format(width: 1280, height: 720, pixel_format: 'MJPG')
      cam.set_fps(30)
    end
  end

  def app = @app ||= Gtk::Application.new('org.rubycam.viewer', :default_flags)
  def window = @window ||= Gtk::ApplicationWindow.new(app)
  def layout = @layout ||= Gtk::Box.new(:horizontal, 12)

  def panel
    @panel ||= ObsbotPanel.new(bot: -> { obsbot },
                               on_wake: -> { wake_camera },
                               on_sleep: -> { sleep_camera },
                               on_compact_toggle: -> { toggle_compact })
  end

  def picture
    @picture ||= Gtk::Picture.new.tap do |pic|
      pic.hexpand = true
      pic.vexpand = true
      pic.margin_start = 12
      pic.margin_top = 12
      pic.margin_bottom = 12
    end
  end

  def sidebar
    @sidebar ||= Gtk::Box.new(:vertical, 6).tap do |box|
      box.margin_top = 12
      box.margin_bottom = 12
      box.width_request = 260
    end
  end

  def sliders
    @sliders ||= SLIDER_KEYS.filter_map do |key|
      device.controls[key]&.then { |ctrl| [key, slider_for(ctrl)] }
    end.to_h
  rescue SystemCallError
    {}
  end

  def reset_button
    @reset_button ||= Gtk::Button.new(label: 'Reset to defaults').tap do |btn|
      btn.margin_top = 12
    end
  end

  def slider_for(ctrl)
    Gtk::Box.new(:vertical, 2).tap do |box|
      box.append(Gtk::Label.new(ctrl.key.to_s).tap { |l| l.halign = :start })
      box.append(
        Gtk::Scale.new(:horizontal,
                       Gtk::Adjustment.new(ctrl.value, ctrl.min, ctrl.max,
                                           ctrl.step, ctrl.step * 10, 0)).tap do |scale|
          scale.draw_value = false
          scale.signal_connect('value-changed') do
            set_control_safely(ctrl.key, scale.value.round)
          end
        end
      )
    end
  end

  def obsbot = @obsbot ||= Rubycam::Obsbot.new(device)

  # Dashboard ⇄ compact widget mode: compact hides the preview and the V4L2
  # sliders, leaving just the OBSBOT panel (like Tiny4Linux's widget mode).
  def toggle_compact
    @compact = !@compact
    picture.visible = !@compact
    sidebar.visible = !@compact
    window.set_default_size(*(@compact ? COMPACT_SIZE : FULL_SIZE))
  end

  # Sleep/wake go through OBSBOT's vendor extension unit — the same command
  # its official software sends. This also wakes the camera after it was put
  # to sleep by physically folding it down.
  def sleep_camera
    @awake = false
    obsbot.sleep!
  rescue SystemCallError
    nil
  end

  def wake_camera
    @awake = true
    obsbot.wake!
    # Grace period for the stream to resume on its own before the
    # watchdog rebuilds it.
    @last_frame_at = monotonic_now
  rescue SystemCallError
    nil
  end

  # After this many consecutive failed polls the camera is treated as gone
  # (a transient EIO during privacy-sleep transitions must not trigger a
  # disruptive reconnect).
  STATUS_FAILURES_BEFORE_RECONNECT = 3

  def start_status_sync
    GLib::Timeout.add_seconds(2) do
      sync_status
      GLib::Source::CONTINUE
    end
  end

  # Poll the camera and mirror its state into the panel, so the UI follows
  # changes made outside the app (folding the camera down, other software).
  def sync_status
    obsbot.status.then do |status|
      @awake = !status[:asleep]
      @failures = 0
      panel.update(status)
    end
  rescue SystemCallError
    @failures = (@failures || 0) + 1
    reconnect_camera if @failures >= STATUS_FAILURES_BEFORE_RECONNECT
  end

  # The camera is gone (unplugged or re-enumerated): drop the dead handle
  # and try to find it again on every poll until it returns.
  def reconnect_camera
    panel.update(nil)
    close_device
    device.then do
      @failures = 0
      @last_frame_at = monotonic_now
      restore_sliders
    end
  rescue SystemCallError
    nil
  end

  def close_device
    @device&.close
  rescue SystemCallError
    nil
  ensure
    @device = nil
    @obsbot = nil
  end

  # When the app started without a camera the sidebar has no sliders yet;
  # build and attach them on first successful (re)connect.
  def restore_sliders
    unless @sliders_in_sidebar || sliders.empty?
      sliders.each_value { |s| sidebar.append(s) }
      sidebar.reorder_child_after(reset_button, sidebar.last_child)
      @sliders_in_sidebar = true
    end
  end

  def reset_controls
    sliders.each_key do |key|
      device.controls[key].then do |ctrl|
        set_control_safely(key, ctrl.default)
        slider_scale(key).value = ctrl.default
      end
    end
  end

  def slider_scale(key) = sliders[key].last_child

  def control_value(key)
    device.controls[key].value
  rescue SystemCallError
    nil
  end

  # Control writes can fail transiently (EIO/EBUSY) while the camera enters
  # or leaves privacy sleep; an exception here must never kill the main loop.
  def set_control_safely(key, value)
    device.controls[key].value = value
  rescue SystemCallError
    nil
  end

  def start_frame_pump
    @last_frame_at = monotonic_now
    @pump = GLib::Timeout.add(FRAME_INTERVAL_MS) do
      pump_one_frame if @device
      GLib::Source::CONTINUE
    end
  end

  # Longer than the camera's first-frame latency, so warmup after a stream
  # (re)start is never mistaken for a dead stream.
  WATCHDOG_SECONDS = 5

  def pump_one_frame
    device.poll_frame.then do |frame|
      if frame
        @last_frame_at = monotonic_now
        show_frame(frame)
      elsif @awake && monotonic_now - (@last_frame_at || 0) > WATCHDOG_SECONDS
        # Video should be flowing but is not (e.g. the camera slept and woke
        # outside our control): rebuild the stream until frames return.
        @last_frame_at = monotonic_now
        warn 'video stalled: rebuilding stream'
        device.restart_streaming
      end
    end
  rescue SystemCallError, RuntimeError
    nil # stream hiccup (e.g. privacy sleep transition): keep the pump alive
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def show_frame(jpeg)
    GdkPixbuf::PixbufLoader.new.tap do |loader|
      loader.write(jpeg)
      loader.close
      picture.pixbuf = loader.pixbuf
    end
  rescue GLib::Error
    nil # drop corrupt frames rather than crashing the pump
  end
end

CameraApp.new(ARGV.fetch(0, '/dev/video0')).build.run
