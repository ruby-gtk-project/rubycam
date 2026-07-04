require 'fiddle'

module Rubycam
  # A V4L2 capture device. Controls are read/written with ioctl; frames are
  # streamed with memory-mapped kernel buffers (uvcvideo does not support
  # plain read()).
  class Device
    BUF_TYPE_VIDEO_CAPTURE = 1
    MEMORY_MMAP = 1
    CTRL_FLAG_NEXT_CTRL = 0x80000000

    PROT_READ = 1
    MAP_SHARED = 1

    LIBC = Fiddle.dlopen(nil)
    MMAP = Fiddle::Function.new(
      LIBC['mmap'],
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT,
       Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG],
      Fiddle::TYPE_VOIDP
    )
    MUNMAP = Fiddle::Function.new(
      LIBC['munmap'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_INT
    )

    attr_reader :path, :driver, :card, :width, :height, :pixel_format

    def self.open(path = '/dev/video0')
      device = new(path)
      if block_given?
        begin
          yield device
        ensure
          device.close
        end
      else
        device
      end
    end

    def initialize(path)
      @path = path
      @io = File.open(path, 'r+')
      @buffers = []
      @streaming = false
      query_capabilities
    end

    def close
      stop_streaming
      @io.close unless @io.closed?
    end

    # ---- Controls ----------------------------------------------------------

    # All controls the driver exposes, keyed by symbol (e.g. :zoom_absolute).
    def controls
      @controls ||= enumerate_controls.to_h { |c| [c.key, c] }
    end

    def [](key) = controls.fetch(key).value

    def []=(key, value)
      controls.fetch(key).value = value
    end

    def get_control(id)
      buf = [id, 0].pack('Ll')
      @io.ioctl(Ioctl::VIDIOC_G_CTRL, buf)
      buf.unpack('Ll')[1]
    end

    def set_control(id, value)
      @io.ioctl(Ioctl::VIDIOC_S_CTRL, [id, value].pack('Ll'))
      value
    end

    # ---- Format / frame rate -----------------------------------------------

    def fourcc(str) = str.unpack1('V')
    def fourcc_to_s(num) = [num].pack('V')

    # Negotiate resolution and pixel format ('MJPG' or 'YUYV'). The driver may
    # adjust the values; the actual result lands in width/height/pixel_format.
    def set_format(width:, height:, pixel_format: 'MJPG')
      buf = [BUF_TYPE_VIDEO_CAPTURE].pack('L') + "\0" * (Ioctl::FORMAT_SIZE - 4)
      @io.ioctl(Ioctl::VIDIOC_G_FMT, buf)
      buf[8, 12] = [width, height, fourcc(pixel_format)].pack('L3')
      @io.ioctl(Ioctl::VIDIOC_S_FMT, buf)
      @width, @height, pix = buf[8, 12].unpack('L3')
      @pixel_format = fourcc_to_s(pix)
      @frame_size = buf[28, 4].unpack1('L')
      [@width, @height, @pixel_format]
    end

    def set_fps(fps)
      buf = [BUF_TYPE_VIDEO_CAPTURE].pack('L') + "\0" * (Ioctl::STREAMPARM_SIZE - 4)
      @io.ioctl(Ioctl::VIDIOC_G_PARM, buf)
      buf[12, 8] = [1, fps].pack('L2')
      @io.ioctl(Ioctl::VIDIOC_S_PARM, buf)
      num, denom = buf[12, 8].unpack('L2')
      denom / num.to_f
    end

    # ---- Streaming -----------------------------------------------------------

    def start_streaming(buffer_count: 4)
      set_format(width: 1920, height: 1080) unless @width
      request_buffers(buffer_count)
      map_buffers
      @buffers.each_index { |i| queue_buffer(i) }
      @io.ioctl(Ioctl::VIDIOC_STREAMON, [BUF_TYPE_VIDEO_CAPTURE].pack('L'))
      @streaming = true
    end

    def stop_streaming
      return unless @streaming

      @io.ioctl(Ioctl::VIDIOC_STREAMOFF, [BUF_TYPE_VIDEO_CAPTURE].pack('L'))
      @buffers.each { |b| MUNMAP.call(b[:ptr], b[:length]) }
      @buffers.clear
      request_buffers(0)
      @streaming = false
    end

    def streaming? = @streaming

    # Tear down and rebuild the buffer queue. Useful when a stream goes
    # quiet after an external event (e.g. a camera's privacy sleep).
    def restart_streaming
      stop_streaming
      start_streaming
    end

    # Block until the next frame is ready and return its bytes as a String.
    # The default timeout is generous because the camera's ISP takes a few
    # seconds to deliver the first frame after STREAMON.
    def capture_frame(timeout: 10.0)
      start_streaming unless @streaming
      IO.select([@io], nil, nil, timeout) or raise "timed out waiting for frame from #{path}"
      buf = dequeue_buffer
      frame = @buffers[buf[:index]][:ptr][0, buf[:bytesused]]
      queue_buffer(buf[:index])
      frame
    end

    # Non-blocking: return the next frame if one is ready, else nil.
    # Suited to GUI main loops that tick faster than the camera delivers.
    def poll_frame
      start_streaming unless @streaming
      IO.select([@io], nil, nil, 0) or return nil
      buf = dequeue_buffer
      frame = @buffers[buf[:index]][:ptr][0, buf[:bytesused]]
      queue_buffer(buf[:index])
      frame
    end

    def each_frame
      start_streaming unless @streaming
      loop { yield capture_frame }
    end

    def to_io = @io

    private

    def query_capabilities
      buf = "\0" * Ioctl::CAPABILITY_SIZE
      @io.ioctl(Ioctl::VIDIOC_QUERYCAP, buf)
      @driver = buf[0, 16].unpack1('Z16')
      @card = buf[16, 32].unpack1('Z32')
    end

    def enumerate_controls
      found = []
      id = CTRL_FLAG_NEXT_CTRL
      loop do
        buf = [id].pack('L') + "\0" * (Ioctl::QUERYCTRL_SIZE - 4)
        begin
          @io.ioctl(Ioctl::VIDIOC_QUERYCTRL, buf)
        rescue Errno::EINVAL
          break
        end
        ctrl_id, type = buf.unpack('L2')
        name = buf[8, 32].unpack1('Z32')
        min, max, step, default = buf[40, 16].unpack('l4')
        flags = buf[56, 4].unpack1('L')
        ctrl = Control.new(self, id: ctrl_id, type:, name:, min:, max:,
                                 step:, default:, flags:)
        found << ctrl unless ctrl.type == :ctrl_class || flags & Control::FLAG_DISABLED != 0
        id = ctrl_id | CTRL_FLAG_NEXT_CTRL
      end
      found
    end

    def request_buffers(count)
      buf = [count, BUF_TYPE_VIDEO_CAPTURE, MEMORY_MMAP].pack('L3') +
            "\0" * (Ioctl::REQUESTBUFFERS_SIZE - 12)
      @io.ioctl(Ioctl::VIDIOC_REQBUFS, buf)
      buf.unpack1('L')
    end

    def buffer_struct(index)
      [index, BUF_TYPE_VIDEO_CAPTURE].pack('L2') +
        "\0" * 52 + [MEMORY_MMAP].pack('L') + "\0" * (Ioctl::BUFFER_SIZE - 64)
    end

    def parse_buffer(buf)
      index, _type, bytesused = buf.unpack('L3')
      offset = buf[64, 4].unpack1('L')
      length = buf[72, 4].unpack1('L')
      { index:, bytesused:, offset:, length: }
    end

    def map_buffers
      count = request_buffers(4)
      @buffers = count.times.map do |i|
        struct = buffer_struct(i)
        @io.ioctl(Ioctl::VIDIOC_QUERYBUF, struct)
        info = parse_buffer(struct)
        ptr = MMAP.call(nil, info[:length], PROT_READ, MAP_SHARED, @io.fileno, info[:offset])
        raise "mmap failed for buffer #{i}" if ptr.to_i == -1 || ptr.to_i == 2**64 - 1

        { ptr: Fiddle::Pointer.new(ptr.to_i), length: info[:length] }
      end
    end

    def queue_buffer(index)
      @io.ioctl(Ioctl::VIDIOC_QBUF, buffer_struct(index))
    end

    def dequeue_buffer
      struct = buffer_struct(0)
      @io.ioctl(Ioctl::VIDIOC_DQBUF, struct)
      parse_buffer(struct)
    end
  end
end
