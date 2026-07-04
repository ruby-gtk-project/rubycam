# Standalone generic V4L2 viewer: live preview plus sliders for whatever
# controls the camera exposes. A trimmed copy of CameraApp with no OBSBOT
# panel or vendor commands, so it works with any UVC webcam. Launched by
# exe/rubycam-v4l2.
require 'gtk4'
require 'rubycam'

module Rubycam
  module GTK; end
end

class Rubycam::GTK::Video4Linux
  FRAME_INTERVAL_MS = 16
  SLIDER_KEYS = %i[pan_absolute tilt_absolute zoom_absolute
                   brightness contrast saturation sharpness].freeze
  WINDOW_SIZE = [1120, 640].freeze

  def initialize(device_path)
    @device_path = device_path
  end

  def build
    app.tap do
      app.signal_connect('activate') do
        app.add_window(window)

        window.tap do |win|
          win.title = window_title
          win.set_default_size(*WINDOW_SIZE)
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
        start_reconnect_watch
        window.present
      end
    end
  end

  # Accepts a device path, a /dev name, or a card/bus substring
  # (e.g. 'Integrated Camera').
  def device
    @device ||= (Rubycam::Device.find(@device_path) or
                 raise Errno::ENOENT, @device_path).tap do |cam|
      cam.set_format(width: 1280, height: 720, pixel_format: 'MJPG')
      cam.set_fps(30)
    end
  end

  def window_title
    device.card
  rescue SystemCallError
    'Rubycam V4L2 (no camera)'
  end

  def app = @app ||= Gtk::Application.new('org.rubycam.v4l2', :default_flags)
  def window = @window ||= Gtk::ApplicationWindow.new(app)
  def layout = @layout ||= Gtk::Box.new(:horizontal, 12)

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
      box.margin_end = 12
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

  # After this many consecutive frame-pump errors the camera is treated as
  # gone (a single hiccup while a stream rebuilds must not drop the handle).
  STREAM_ERRORS_BEFORE_DROP = 60

  # Drop the dead handle and try to find the camera again on every tick until
  # it returns (unplugged or re-enumerated).
  def start_reconnect_watch
    GLib::Timeout.add_seconds(2) do
      reconnect_camera unless @device
      GLib::Source::CONTINUE
    end
  end

  def reconnect_camera
    device.then do
      @stream_errors = 0
      @last_frame_at = monotonic_now
      restore_sliders
      window.title = window_title
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

  # Control writes can fail transiently (EIO/EBUSY); an exception here must
  # never kill the main loop.
  def set_control_safely(key, value)
    device.controls[key].value = value
  rescue SystemCallError
    nil
  end

  def start_frame_pump
    @last_frame_at = monotonic_now
    @stream_errors = 0
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
        @stream_errors = 0
        show_frame(frame)
      elsif monotonic_now - (@last_frame_at || 0) > WATCHDOG_SECONDS
        # Video should be flowing but is not: rebuild the stream until frames
        # return.
        @last_frame_at = monotonic_now
        warn 'video stalled: rebuilding stream'
        device.restart_streaming
      end
    end
  rescue SystemCallError, RuntimeError
    # Sustained errors mean the camera is gone: drop the handle so the
    # reconnect watch re-finds it. A one-off hiccup is ignored.
    @stream_errors = (@stream_errors || 0) + 1
    close_device if @stream_errors >= STREAM_ERRORS_BEFORE_DROP
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
