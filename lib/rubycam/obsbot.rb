module Rubycam
  # OBSBOT vendor commands, spoken over the camera's UVC Extension Unit
  # (unit 2, GUID 9a1e7291-6843-4683-6d92-39bc7906ee49) via the uvcvideo
  # driver's UVCIOC_CTRL_QUERY ioctl. Protocol reverse-engineered by the
  # Tiny4Linux project (https://github.com/OpenFoxes/Tiny4Linux).
  class Obsbot
    UNIT = 0x02
    SELECTOR_COMMAND = 0x02
    SELECTOR_STATUS = 0x06
    PAYLOAD_SIZE = 60

    UVC_SET_CUR = 0x01
    UVC_GET_CUR = 0x81

    # struct uvc_xu_control_query { u8 unit; u8 selector; u8 query;
    #   u16 size; u8 *data; } — 16 bytes with padding on 64-bit.
    UVCIOC_CTRL_QUERY = Ioctl.iowr('u', 0x21, 16)

    DEVICE_HINT = 'OBSBOT Tiny 2'.freeze

    # Command packets sent to selector 0x02:
    #   aa 25 | seq(2) | 0c 00 | checksum(2) | group(6) | cmd(6) | appendix(16)
    # Sequence numbers and checksums are replayed verbatim from captures of
    # the official software; the camera accepts them as-is.
    def self.command02(seq:, checksum:, group:, cmd:, appendix: [0] * 16)
      ([0xaa, 0x25] + seq + [0x0c, 0x00] + checksum + group + cmd + appendix)
        .pack('C*')
    end

    GROUP_SLEEP = [0x0a, 0x02, 0xc2, 0xa0, 0x04, 0x00].freeze
    WAKE_PACKET = command02(seq: [0xa5, 0x00], checksum: [0x5f, 0xef],
                            group: GROUP_SLEEP,
                            cmd: [0xbe, 0x07, 0x00, 0x00, 0x00, 0x00])
    SLEEP_PACKET = command02(seq: [0x42, 0x00], checksum: [0xea, 0x63],
                             group: GROUP_SLEEP,
                             cmd: [0xbf, 0xfb, 0x01, 0x00, 0x00, 0x00])

    GROUP_TRACKING_SPEED = [0x0a, 0x04, 0xc4, 0x0c, 0x01, 0x00].freeze
    TRACKING_SPEED_PACKETS = {
      standard: command02(seq: [0x20, 0x00], checksum: [0xab, 0xcb],
                          group: GROUP_TRACKING_SPEED,
                          cmd: [0xe6, 0x3f, 0x00, 0x00, 0x00, 0x00]),
      sport: command02(seq: [0x21, 0x00], checksum: [0xfa, 0x0e],
                       group: GROUP_TRACKING_SPEED,
                       cmd: [0x67, 0xfe, 0x02, 0x00, 0x00, 0x00])
    }.freeze

    GROUP_PRESETS = [0x0a, 0x04, 0xc4, 0x39, 0x14, 0x00].freeze
    PRESET_APPENDIX = ([0x00, 0x00, 0x80, 0x3f] * 4).freeze # 1.0f × 4
    PRESET_PACKETS = [
      command02(seq: [0x20, 0x00], checksum: [0x6b, 0xdc], group: GROUP_PRESETS,
                cmd: [0xd6, 0xfb, 0x00, 0x00, 0x00, 0x00], appendix: PRESET_APPENDIX),
      command02(seq: [0x1a, 0x00], checksum: [0x4b, 0x03], group: GROUP_PRESETS,
                cmd: [0xeb, 0x2a, 0x01, 0x00, 0x00, 0x00], appendix: PRESET_APPENDIX),
      command02(seq: [0x26, 0x00], checksum: [0x8b, 0xc3], group: GROUP_PRESETS,
                cmd: [0xaf, 0x19, 0x02, 0x00, 0x00, 0x00], appendix: PRESET_APPENDIX)
    ].freeze

    # Switching exposure mode is two-stage: a mode-type packet on 0x02
    # (manual vs. automatic), then for the automatic flavours a follow-up
    # on 0x06 choosing global or face metering.
    GROUP_EXPOSURE_TYPE = [0x0a, 0x02, 0x82, 0x29, 0x05, 0x00].freeze
    EXPOSURE_TYPE_PACKETS = {
      manual: command02(seq: [0x16, 0x00], checksum: [0x58, 0x91],
                        group: GROUP_EXPOSURE_TYPE,
                        cmd: [0xb2, 0xaf, 0x02, 0x04, 0x00, 0x00]),
      auto: command02(seq: [0x15, 0x00], checksum: [0xa8, 0x9e],
                      group: GROUP_EXPOSURE_TYPE,
                      cmd: [0xf9, 0x27, 0x01, 0x32, 0x00, 0x00])
    }.freeze
    EXPOSURE_MODES = { manual: nil, global: [0x03, 0x01, 0x00],
                       face: [0x03, 0x01, 0x01] }.freeze

    # AI tracking modes, keyed by symbol; values are the two mode bytes as
    # sent in the set command and reported at 0x18/0x1c of the status block.
    AI_MODES = { no_tracking: [0, 0], normal_tracking: [2, 0],
                 upper_body: [2, 1], close_up: [2, 2], headless: [2, 3],
                 lower_body: [2, 4], desk_mode: [5, 0], whiteboard: [4, 0],
                 hand: [6, 0], group: [1, 0] }.freeze
    AI_MODE_BY_BYTES = AI_MODES.invert.freeze

    TRACKING_SPEEDS = %i[standard sport].freeze

    # If set, sent commands and raw status reads are logged to stderr.
    attr_accessor :debug

    def initialize(device)
      @device = device
      @debug = false
    end

    def wake! = send_command(WAKE_PACKET)
    def sleep! = send_command(SLEEP_PACKET)

    def ai_mode=(mode)
      m, n = AI_MODES.fetch(mode)
      send_status_command([0x16, 0x02, m, n].pack('C*'))
    end

    def tracking_speed=(speed)
      send_command(TRACKING_SPEED_PACKETS.fetch(speed))
    end

    # Move the gimbal to a stored preset position (0..2). The camera ignores
    # this while tracking, so callers normally switch to :no_tracking first.
    def goto_preset(number)
      send_command(PRESET_PACKETS.fetch(number))
    end

    def hdr=(on)
      send_status_command([0x01, 0x01, on ? 1 : 0].pack('C*'))
    end

    def exposure_mode=(mode)
      metering = EXPOSURE_MODES.fetch(mode)
      send_command(EXPOSURE_TYPE_PACKETS.fetch(metering ? :auto : :manual))
      send_status_command(metering.pack('C*')) if metering
    end

    # NOTE: on newer Tiny 2 firmware the status block can lag behind mode
    # changes by several seconds; treat it as eventually consistent.
    def status
      raw_status.then do |bytes|
        { asleep: bytes[0x02] == 1,
          hdr: bytes[0x06] != 0,
          ai_mode: AI_MODE_BY_BYTES.fetch([bytes[0x18], bytes[0x1c]], :unknown),
          tracking_speed: decode_speed(bytes) }
      end
    end

    def asleep? = status[:asleep]

    # ---- Debug console -------------------------------------------------------
    # Raw access to the extension unit, mirroring Tiny4Linux's debug area.

    def send_hex(hex, selector: SELECTOR_STATUS)
      send_to(selector, [hex.gsub(/\s/, '')].pack('H*'))
    end

    # Current 60-byte state of a selector as a hex string.
    def dump(selector = SELECTOR_STATUS)
      xu_query(UVC_GET_CUR, selector).unpack1('H*')
    end

    private

    # Tiny4Linux reads speed at 0x21 (0=standard, 2=sport), but newer Tiny 2
    # firmware keeps a constant 3 there and reports the speed at 0x24.
    def decode_speed(bytes)
      [bytes[0x21], bytes[0x24]].find { |b| [0, 2].include?(b) } == 2 ? :sport : :standard
    end

    def send_command(packet) = send_to(SELECTOR_COMMAND, packet)
    def send_status_command(packet) = send_to(SELECTOR_STATUS, packet)

    def send_to(selector, packet)
      warn format('obsbot -> 0x%02x: %s', selector, packet.unpack1('H*')) if debug
      xu_query(UVC_SET_CUR, selector, packet)
      true
    end

    def raw_status
      xu_query(UVC_GET_CUR, SELECTOR_STATUS).tap do |raw|
        warn "obsbot <- status: #{raw.unpack1('H*')}" if debug
      end.bytes
    end

    def xu_query(query, selector, payload = '')
      buffer = Fiddle::Pointer.malloc(PAYLOAD_SIZE, Fiddle::RUBY_FREE)
      buffer[0, payload.bytesize] = payload unless payload.empty?
      request = [UNIT, selector, query, PAYLOAD_SIZE, buffer.to_i].pack('C3xvx2Q')
      @device.to_io.ioctl(UVCIOC_CTRL_QUERY, request)
      buffer[0, PAYLOAD_SIZE]
    end
  end
end
