#!/usr/bin/env ruby
# Live OBSBOT viewer: video preview plus gimbal/zoom/image controls.
# Run inside the dev shell: bundle exec ruby app/camera_app.rb [device]
require 'gtk4'
require_relative '../lib/rubycam'

class CameraApp
  FRAME_INTERVAL_MS = 16
  SLIDER_KEYS = %i[pan_absolute tilt_absolute zoom_absolute
                   brightness contrast saturation sharpness].freeze

  def initialize(device_path)
    @device_path = device_path
    @awake = true
  end

  def build
    app.tap do
      app.signal_connect('activate') do
        app.add_window(window)

        window.tap do |win|
          win.title = device.card
          win.set_default_size(1100, 620)
          win.child = layout

          win.signal_connect('close-request') do
            GLib::Source.remove(@pump) if @pump
            device.close
            false
          end
        end

        layout.tap do |l|
          l.append(picture)
          l.append(sidebar)

          sidebar.tap do |side|
            side.append(power_row)
            sliders.each_value { |s| side.append(s) }
            side.append(reset_button)

            power_row.tap do |row|
              row.append(power_label)
              row.append(power_switch)

              power_switch.tap do |sw|
                sw.signal_connect('state-set') do |_, on|
                  on ? wake_camera : sleep_camera unless @syncing_switch
                  false
                end
              end
            end

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

  def device
    @device ||= Rubycam::Device.open(@device_path).tap do |cam|
      cam.set_format(width: 1280, height: 720, pixel_format: 'MJPG')
      cam.set_fps(30)
    end
  end

  def app = @app ||= Gtk::Application.new('org.rubycam.viewer', :default_flags)
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
      box.margin_end = 12
      box.margin_top = 12
      box.margin_bottom = 12
      box.width_request = 260
    end
  end

  def power_row = @power_row ||= Gtk::Box.new(:horizontal, 8)

  def power_label
    @power_label ||= Gtk::Label.new('Camera').tap do |l|
      l.halign = :start
      l.hexpand = true
    end
  end

  def power_switch
    @power_switch ||= Gtk::Switch.new.tap do |sw|
      sw.active = true
      sw.halign = :end
    end
  end

  def sliders
    @sliders ||= SLIDER_KEYS.filter_map do |key|
      device.controls[key]&.then { |ctrl| [key, slider_for(ctrl)] }
    end.to_h
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

  # Keep the power switch honest when sleep state changes outside the app
  # (physically folding the camera down or waking it by hand).
  def start_status_sync
    GLib::Timeout.add_seconds(2) do
      begin
        obsbot.asleep?.then do |asleep|
          if asleep == @awake # switch and camera disagree
            @awake = !asleep
            @syncing_switch = true
            power_switch.active = @awake
            @syncing_switch = false
          end
        end
      rescue SystemCallError
        nil
      end
      GLib::Source::CONTINUE
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
      pump_one_frame
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
