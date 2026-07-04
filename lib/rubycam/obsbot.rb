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

    # Command packets: aa 25 | seq(2) | 0c 00 | checksum(2) | group(6) | cmd(6)
    GROUP_SLEEP = [0x0a, 0x02, 0xc2, 0xa0, 0x04, 0x00].freeze
    WAKE_PACKET = ([0xaa, 0x25, 0xa5, 0x00, 0x0c, 0x00, 0x5f, 0xef] +
                   GROUP_SLEEP + [0xbe, 0x07, 0x00, 0x00, 0x00, 0x00]).pack('C*')
    SLEEP_PACKET = ([0xaa, 0x25, 0x42, 0x00, 0x0c, 0x00, 0xea, 0x63] +
                    GROUP_SLEEP + [0xbf, 0xfb, 0x01, 0x00, 0x00, 0x00]).pack('C*')

    AI_MODES = { [0, 0] => :no_tracking, [2, 0] => :normal_tracking,
                 [2, 1] => :upper_body, [2, 2] => :close_up, [2, 3] => :headless,
                 [2, 4] => :lower_body, [5, 0] => :desk_mode, [4, 0] => :whiteboard,
                 [6, 0] => :hand, [1, 0] => :group }.freeze

    def initialize(device)
      @device = device
    end

    def wake! = send_command(WAKE_PACKET)
    def sleep! = send_command(SLEEP_PACKET)

    def status
      raw_status.then do |bytes|
        { asleep: bytes[0x02] == 1,
          hdr: bytes[0x06] != 0,
          ai_mode: AI_MODES.fetch([bytes[0x18], bytes[0x1c]], :unknown) }
      end
    end

    def asleep? = status[:asleep]

    private

    def send_command(packet)
      xu_query(UVC_SET_CUR, SELECTOR_COMMAND, packet)
      true
    end

    def raw_status
      xu_query(UVC_GET_CUR, SELECTOR_STATUS).bytes
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
