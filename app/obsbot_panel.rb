# OBSBOT control panel: the Tiny4Linux GUI feature set as one widget —
# sleep/wake, live status, presets, tracking modes, tracking speed, HDR,
# exposure modes and a raw-hex debug console. Talks to the camera through
# the injected bot getter so a reconnect (new Obsbot) is picked up
# transparently.
class ObsbotPanel
  AI_MODE_LABELS = { no_tracking: 'Static', normal_tracking: 'Normal',
                     close_up: 'Close-up', upper_body: 'Upper Body',
                     headless: 'Headless', lower_body: 'Lower Body',
                     desk_mode: 'Desk', whiteboard: 'Whiteboard',
                     hand: 'Hand', group: 'Group' }.freeze
  SPEED_LABELS = { standard: 'Standard', sport: 'Sport' }.freeze
  EXPOSURE_LABELS = { manual: 'Manual', global: 'Global', face: 'Face' }.freeze
  STATS = { sleep: 'State', tracking: 'Tracking', speed: 'Speed',
            hdr: 'HDR', version: 'Version' }.freeze

  def initialize(bot:, on_wake:, on_sleep:, on_compact_toggle:)
    @bot = bot
    @on_wake = on_wake
    @on_sleep = on_sleep
    @on_compact_toggle = on_compact_toggle
  end

  def build
    @build ||= scroller.tap do |sc|
      sc.child = root

      root.tap do |r|
        r.append(header_row)
        r.append(connection_label)
        r.append(power_row)
        r.append(stats_grid)
        r.append(presets_row)
        r.append(tracking_heading)
        r.append(tracking_grid)
        r.append(speed_row)
        r.append(hdr_row)
        r.append(exposure_row)
        r.append(debug_toggle)
        r.append(debug_revealer)

        header_row.tap do |row|
          row.append(title_label)
          row.append(compact_button)

          compact_button.signal_connect('clicked') { @on_compact_toggle.call }
        end

        power_row.tap do |row|
          row.append(power_label)
          row.append(power_switch)

          power_switch.signal_connect('state-set') do |_, on|
            (on ? @on_wake : @on_sleep).call unless @syncing
            false
          end
        end

        stats_grid.tap do |g|
          STATS.each_key.with_index do |key, i|
            g.attach(stat_name_labels[key], 0, i, 1, 1)
            g.attach(stat_labels[key], 1, i, 1, 1)
          end
          stat_labels[:version].label = Rubycam::VERSION
        end

        presets_row.tap do |row|
          row.append(presets_label)
          preset_buttons.each_with_index do |btn, i|
            row.append(btn)
            btn.signal_connect('clicked') { goto_preset(i) }
          end
        end

        tracking_grid.tap do |g|
          tracking_buttons.each_with_index do |(mode, btn), i|
            g.attach(btn, i % 2, i / 2, 1, 1)
            btn.signal_connect('clicked') { set_tracking(mode) }
          end
        end

        speed_row.tap do |row|
          row.append(speed_label)
          speed_buttons.each do |speed, btn|
            row.append(btn)
            btn.signal_connect('clicked') { set_speed(speed) }
          end
        end

        hdr_row.tap do |row|
          row.append(hdr_label)
          row.append(hdr_toggle)

          hdr_toggle.signal_connect('toggled') do
            command { |bot| bot.hdr = hdr_toggle.active? } unless @syncing
          end
        end

        exposure_row.tap do |row|
          row.append(exposure_label)
          exposure_buttons.each do |mode, btn|
            row.append(btn)
            btn.signal_connect('clicked') { command { |bot| bot.exposure_mode = mode } }
          end
        end

        debug_toggle.signal_connect('toggled') { toggle_debug }

        debug_revealer.tap do |rev|
          rev.child = debug_box

          debug_box.tap do |dbg|
            dbg.append(hex06_row)
            dbg.append(hex02_row)
            dbg.append(dump_row)
            dbg.append(debug_output)

            hex06_row.tap do |row|
              row.append(hex06_entry)
              row.append(hex06_send)
              hex06_entry.signal_connect('activate') { send_hex(hex06_entry, Rubycam::Obsbot::SELECTOR_STATUS) }
              hex06_send.signal_connect('clicked') { send_hex(hex06_entry, Rubycam::Obsbot::SELECTOR_STATUS) }
            end

            hex02_row.tap do |row|
              row.append(hex02_entry)
              row.append(hex02_send)
              hex02_entry.signal_connect('activate') { send_hex(hex02_entry, Rubycam::Obsbot::SELECTOR_COMMAND) }
              hex02_send.signal_connect('clicked') { send_hex(hex02_entry, Rubycam::Obsbot::SELECTOR_COMMAND) }
            end

            dump_row.tap do |row|
              row.append(dump06_button)
              row.append(dump02_button)
              dump06_button.signal_connect('clicked') { show_dump(Rubycam::Obsbot::SELECTOR_STATUS) }
              dump02_button.signal_connect('clicked') { show_dump(Rubycam::Obsbot::SELECTOR_COMMAND) }
            end
          end
        end
      end
    end
  end

  # Mirror camera state into the panel. A nil status means no camera.
  def update(status)
    @syncing = true
    connection_label.label = status ? 'Connected' : 'No camera detected — searching…'
    stat_labels[:sleep].label = status ? (status[:asleep] ? 'Sleeping' : 'Awake') : '—'
    stat_labels[:tracking].label = status ? AI_MODE_LABELS.fetch(status[:ai_mode], 'Unknown') : '—'
    stat_labels[:speed].label = status ? SPEED_LABELS.fetch(status[:tracking_speed]) : '—'
    stat_labels[:hdr].label = status ? (status[:hdr] ? 'On' : 'Off') : '—'
    status&.then do |s|
      power_switch.active = !s[:asleep]
      hdr_toggle.active = s[:hdr]
      highlight(tracking_buttons, s[:ai_mode])
      highlight(speed_buttons, s[:tracking_speed])
    end
    @syncing = false
  end

  private

  # Commands can fail transiently (camera asleep or unplugged) or on bad
  # hex input; report failure instead of crashing the main loop.
  def command
    yield @bot.call
    true
  rescue SystemCallError, ArgumentError
    false
  end

  def highlight(buttons, active_key)
    buttons.each do |key, btn|
      key == active_key ? btn.add_css_class('suggested-action') : btn.remove_css_class('suggested-action')
    end
  end

  def set_tracking(mode)
    command { |bot| bot.ai_mode = mode }
    highlight(tracking_buttons, mode)
  end

  def set_speed(speed)
    command { |bot| bot.tracking_speed = speed }
    highlight(speed_buttons, speed)
  end

  # The camera ignores preset moves while tracking, so tracking is switched
  # off first — same order as the official software.
  def goto_preset(number)
    command do |bot|
      bot.ai_mode = :no_tracking
      bot.goto_preset(number)
    end
    highlight(tracking_buttons, :no_tracking)
  end

  def toggle_debug
    debug_revealer.reveal_child = debug_toggle.active?
    command { |bot| bot.debug = debug_toggle.active? }
  end

  def send_hex(entry, selector)
    debug_output.label =
      command { |bot| bot.send_hex(entry.text, selector: selector) } ? 'Sent.' : 'Failed (bad hex or camera error).'
  end

  def show_dump(selector)
    command { |bot| debug_output.label = bot.dump(selector).scan(/.{1,8}/).join(' ') }
      .then { |ok| debug_output.label = 'Failed (camera error).' unless ok }
  end

  def scroller
    @scroller ||= Gtk::ScrolledWindow.new.tap do |sc|
      sc.set_policy(:never, :automatic)
      sc.width_request = 330
    end
  end

  def root
    @root ||= Gtk::Box.new(:vertical, 10).tap do |b|
      b.margin_top = 12
      b.margin_bottom = 12
      b.margin_start = 6
      b.margin_end = 12
    end
  end

  def header_row = @header_row ||= Gtk::Box.new(:horizontal, 8)

  def title_label
    @title_label ||= Gtk::Label.new('OBSBOT').tap do |l|
      l.halign = :start
      l.hexpand = true
      l.add_css_class('heading')
    end
  end

  def compact_button
    @compact_button ||= Gtk::Button.new.tap do |b|
      b.icon_name = 'view-restore-symbolic'
      b.tooltip_text = 'Toggle compact widget mode'
      b.halign = :end
    end
  end

  def connection_label
    @connection_label ||= Gtk::Label.new('Connecting…').tap do |l|
      l.xalign = 0
      l.add_css_class('dim-label')
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

  def stats_grid
    @stats_grid ||= Gtk::Grid.new.tap do |g|
      g.row_spacing = 4
      g.column_spacing = 12
    end
  end

  def stat_name_labels
    @stat_name_labels ||= STATS.to_h do |key, name|
      [key, Gtk::Label.new("#{name}:").tap do |l|
        l.xalign = 0
        l.hexpand = true
        l.add_css_class('dim-label')
      end]
    end
  end

  def stat_labels
    @stat_labels ||= STATS.keys.to_h do |key|
      [key, Gtk::Label.new('—').tap { |l| l.xalign = 1 }]
    end
  end

  def presets_row = @presets_row ||= Gtk::Box.new(:horizontal, 6)

  def presets_label
    @presets_label ||= Gtk::Label.new('Presets:').tap do |l|
      l.xalign = 0
      l.hexpand = true
    end
  end

  def preset_buttons
    @preset_buttons ||= (1..3).map do |n|
      Gtk::Button.new(label: n.to_s).tap { |b| b.tooltip_text = "Go to preset position #{n}" }
    end
  end

  def tracking_heading
    @tracking_heading ||= Gtk::Label.new('Tracking mode').tap do |l|
      l.xalign = 0
      l.add_css_class('dim-label')
    end
  end

  def tracking_grid
    @tracking_grid ||= Gtk::Grid.new.tap do |g|
      g.row_spacing = 6
      g.column_spacing = 6
      g.column_homogeneous = true
    end
  end

  def tracking_buttons
    @tracking_buttons ||= AI_MODE_LABELS.transform_values do |label|
      Gtk::Button.new(label: label).tap { |b| b.tooltip_text = "Set tracking mode: #{label}" }
    end
  end

  def speed_row = @speed_row ||= Gtk::Box.new(:horizontal, 6)

  def speed_label
    @speed_label ||= Gtk::Label.new('Speed:').tap do |l|
      l.xalign = 0
      l.hexpand = true
    end
  end

  def speed_buttons
    @speed_buttons ||= SPEED_LABELS.transform_values do |label|
      Gtk::Button.new(label: label).tap { |b| b.tooltip_text = "Set tracking speed: #{label}" }
    end
  end

  def hdr_row = @hdr_row ||= Gtk::Box.new(:horizontal, 6)

  def hdr_label
    @hdr_label ||= Gtk::Label.new('HDR:').tap do |l|
      l.xalign = 0
      l.hexpand = true
    end
  end

  def hdr_toggle
    @hdr_toggle ||= Gtk::ToggleButton.new.tap do |b|
      b.label = 'HDR'
      b.tooltip_text = 'Toggle HDR'
    end
  end

  def exposure_row = @exposure_row ||= Gtk::Box.new(:horizontal, 6)

  def exposure_label
    @exposure_label ||= Gtk::Label.new('Exposure:').tap do |l|
      l.xalign = 0
      l.hexpand = true
    end
  end

  def exposure_buttons
    @exposure_buttons ||= EXPOSURE_LABELS.transform_values do |label|
      Gtk::Button.new(label: label).tap { |b| b.tooltip_text = "Set exposure mode: #{label}" }
    end
  end

  def debug_toggle
    @debug_toggle ||= Gtk::ToggleButton.new.tap do |b|
      b.label = 'Debug console'
      b.tooltip_text = 'Log commands to stderr and send raw hex'
    end
  end

  def debug_revealer
    @debug_revealer ||= Gtk::Revealer.new.tap do |r|
      r.transition_type = :slide_down
      r.reveal_child = false
    end
  end

  def debug_box = @debug_box ||= Gtk::Box.new(:vertical, 6)
  def hex06_row = @hex06_row ||= Gtk::Box.new(:horizontal, 6)
  def hex02_row = @hex02_row ||= Gtk::Box.new(:horizontal, 6)
  def dump_row = @dump_row ||= Gtk::Box.new(:horizontal, 6)

  def hex06_entry
    @hex06_entry ||= Gtk::Entry.new.tap do |e|
      e.placeholder_text = '0x06 hex bytes'
      e.hexpand = true
    end
  end

  def hex02_entry
    @hex02_entry ||= Gtk::Entry.new.tap do |e|
      e.placeholder_text = '0x02 hex bytes'
      e.hexpand = true
    end
  end

  def hex06_send = @hex06_send ||= Gtk::Button.new(label: 'Send')
  def hex02_send = @hex02_send ||= Gtk::Button.new(label: 'Send')
  def dump06_button = @dump06_button ||= Gtk::Button.new(label: 'Dump 0x06')
  def dump02_button = @dump02_button ||= Gtk::Button.new(label: 'Dump 0x02')

  def debug_output
    @debug_output ||= Gtk::Label.new('').tap do |l|
      l.xalign = 0
      l.wrap = true
      l.wrap_mode = :char
      l.selectable = true
      l.add_css_class('monospace')
    end
  end
end
