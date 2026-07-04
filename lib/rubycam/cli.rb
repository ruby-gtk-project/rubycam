require 'dry/cli'
require_relative '../rubycam'

module Rubycam
  # Command-line companion to the GTK viewer (bin/rubycam). Generic V4L2
  # commands default to /dev/video0 like the GUI; OBSBOT vendor commands
  # default to finding the camera by name.
  module CLI
    module Commands
      extend Dry::CLI::Registry

      # Base for commands that target one camera. Subclasses inherit the
      # --device option (dry-cli copies params down the class hierarchy).
      class VideoCommand < Dry::CLI::Command
        option :device, type: :string, aliases: ['-d'], default: '/dev/video0',
               desc: 'Device path, /dev name, or card/bus-name substring'

        private

        def with_device(options)
          hint = options.fetch(:device)
          device = Device.find(hint) or
            abort "rubycam: no camera matches #{hint.inspect}"
          begin
            yield device
          ensure
            device.close
          end
        end

        def fetch_control(device, name)
          device.controls.fetch(name.to_sym) do
            abort "rubycam: unknown control #{name} (see `controls`)"
          end
        end

        def pick(value, allowed)
          allowed.find { |a| a.to_s == value } or
            abort "rubycam: expected one of: #{allowed.join(', ')}"
        end
      end

      class ObsbotCommand < VideoCommand
        option :device, type: :string, aliases: ['-d'], default: Obsbot::DEVICE_HINT,
               desc: 'Device path, /dev name, or card/bus-name substring'
        option :debug, type: :boolean, default: false,
               desc: 'Log extension-unit traffic to stderr'

        private

        def with_obsbot(options)
          with_device(options) do |device|
            bot = Obsbot.new(device)
            bot.debug = options[:debug]
            yield bot
          end
        end
      end

      class Version < Dry::CLI::Command
        desc 'Print version'
        def call(**) = puts(VERSION)
      end

      class Devices < Dry::CLI::Command
        desc 'List video capture devices'

        def call(**)
          Rubycam.devices.each do |dev|
            meta = dev.device_caps & Device::CAP_META_CAPTURE != 0
            puts format('%-14s %-28s %s%s', dev.path, dev.card, dev.bus_info,
                        meta ? '  (metadata)' : '')
            dev.close
          end
        end
      end

      class Info < VideoCommand
        desc 'Show device identity (driver, card, bus)'

        def call(**options)
          with_device(options) do |dev|
            { path: dev.path, driver: dev.driver, card: dev.card,
              bus: dev.bus_info }.each { |k, v| puts format('%-8s %s', "#{k}:", v) }
          end
        end
      end

      class Controls < VideoCommand
        desc 'List V4L2 controls with ranges and current values'

        def call(**options)
          with_device(options) do |dev|
            dev.controls.each_value do |c|
              notes = [(' [read-only]' if c.read_only?),
                       (' [inactive]' if c.inactive?)].compact.join
              puts "#{c}#{notes}"
            end
          end
        end
      end

      class Get < VideoCommand
        desc 'Read one V4L2 control'
        argument :control, required: true, desc: 'Control key (see `controls`)'

        def call(control:, **options)
          with_device(options) { |dev| puts fetch_control(dev, control).value }
        end
      end

      class Set < VideoCommand
        desc 'Set one V4L2 control'
        argument :control, required: true, desc: 'Control key (see `controls`)'
        argument :value, required: true, desc: 'Integer value (clamped to range)'

        def call(control:, value:, **options)
          with_device(options) do |dev|
            ctrl = fetch_control(dev, control)
            ctrl.value = Integer(value)
            puts "#{ctrl.key} = #{ctrl.value}"
          end
        rescue ArgumentError
          abort "rubycam: value must be an integer, got #{value.inspect}"
        end
      end

      class Reset < VideoCommand
        desc 'Reset all writable controls to their defaults'

        def call(**options)
          with_device(options) do |dev|
            dev.controls.each_value do |c|
              next if c.read_only? || c.type == :button

              begin
                c.value = c.default
              rescue SystemCallError
                # inactive controls (e.g. manual exposure in auto mode) reject writes
              end
            end
          end
        end
      end

      class Snapshot < VideoCommand
        desc 'Capture a single frame to a JPEG file'
        argument :path, desc: 'Output file (default: snapshot.jpg)'
        option :width, type: :integer, default: 1920
        option :height, type: :integer, default: 1080

        def call(path: 'snapshot.jpg', **options)
          with_device(options) do |dev|
            dev.set_format(width: options.fetch(:width).to_i,
                           height: options.fetch(:height).to_i, pixel_format: 'MJPG')
            File.binwrite(path, dev.capture_frame)
            puts "#{dev.card}: wrote #{path} (#{dev.width}x#{dev.height} #{dev.pixel_format})"
          end
        end
      end

      class Status < ObsbotCommand
        desc 'Show OBSBOT status (sleep, AI mode, tracking speed, HDR)'

        def call(**options)
          with_obsbot(options) do |bot|
            bot.status.each { |k, v| puts format('%-16s %s', "#{k}:", v) }
          end
        end
      end

      class Wake < ObsbotCommand
        desc 'Wake the camera from privacy sleep'
        def call(**options) = with_obsbot(options, &:wake!)
      end

      class Sleep < ObsbotCommand
        desc 'Put the camera into privacy sleep'
        def call(**options) = with_obsbot(options, &:sleep!)
      end

      class Track < ObsbotCommand
        desc "Set AI tracking mode (#{Obsbot::AI_MODES.keys.join(', ')})"
        argument :mode, required: true, desc: 'Tracking mode'

        def call(mode:, **options)
          with_obsbot(options) { |bot| bot.ai_mode = pick(mode, Obsbot::AI_MODES.keys) }
        end
      end

      class Speed < ObsbotCommand
        desc 'Set tracking speed (standard, sport)'
        argument :speed, required: true, desc: 'Tracking speed'

        def call(speed:, **options)
          with_obsbot(options) do |bot|
            bot.tracking_speed = pick(speed, Obsbot::TRACKING_SPEEDS)
          end
        end
      end

      class Hdr < ObsbotCommand
        desc 'Switch HDR on or off'
        argument :state, required: true, desc: 'on or off'

        def call(state:, **options)
          with_obsbot(options) { |bot| bot.hdr = pick(state, %i[on off]) == :on }
        end
      end

      class Exposure < ObsbotCommand
        desc 'Set exposure mode (manual, global, face)'
        argument :mode, required: true, desc: 'Exposure mode'

        def call(mode:, **options)
          with_obsbot(options) do |bot|
            bot.exposure_mode = pick(mode, Obsbot::EXPOSURE_MODES.keys)
          end
        end
      end

      class Preset < ObsbotCommand
        desc 'Move gimbal to a preset position (tracking is switched off first)'
        argument :number, required: true, desc: 'Preset number (1-3)'

        def call(number:, **options)
          n = Integer(number, exception: false)
          abort 'rubycam: preset must be 1-3' unless n && (1..3).cover?(n)
          with_obsbot(options) do |bot|
            bot.ai_mode = :no_tracking
            bot.goto_preset(n - 1)
          end
        end
      end

      class XuDump < ObsbotCommand
        desc 'Hex-dump the 60-byte state of an extension-unit selector'
        argument :selector, desc: 'Selector, e.g. 0x06 (default) or 0x02'

        def call(selector: '0x06', **options)
          with_obsbot(options) { |bot| puts bot.dump(Integer(selector)) }
        end
      end

      class XuSend < ObsbotCommand
        desc 'Send raw hex bytes to an extension-unit selector'
        argument :hex, required: true, desc: "Hex bytes, e.g. '16 02 02 00'"
        option :selector, default: '0x06', desc: 'Selector to send to'

        def call(hex:, **options)
          with_obsbot(options) do |bot|
            bot.send_hex(hex, selector: Integer(options.fetch(:selector)))
          end
        end
      end

      register 'version', Version, aliases: ['-v', '--version']
      register 'devices', Devices
      register 'info', Info
      register 'controls', Controls
      register 'get', Get
      register 'set', Set
      register 'reset', Reset
      register 'snapshot', Snapshot
      register 'status', Status
      register 'wake', Wake
      register 'sleep', Sleep
      register 'track', Track
      register 'speed', Speed
      register 'hdr', Hdr
      register 'exposure', Exposure
      register 'preset', Preset
      register 'xu' do |xu|
        xu.register 'dump', XuDump
        xu.register 'send', XuSend
      end
    end
  end
end
