# V4L2 ioctl plumbing: request-code computation and struct layouts.
#
# ioctl request codes follow the kernel's _IOC macro:
#   dir(2 bits) | size(14 bits) | type(8 bits) | nr(8 bits)
# Struct sizes below must match the C layouts in <linux/videodev2.h>
# on 64-bit; each SIZE constant is asserted against its pack template.
module Rubycam
  module Ioctl
    NONE  = 0
    WRITE = 1
    READ  = 2

    def self.ioc(dir, type, nr, size) = (dir << 30) | (size << 16) | (type.ord << 8) | nr
    def self.iowr(type, nr, size) = ioc(WRITE | READ, type, nr, size)
    def self.ior(type, nr, size)  = ioc(READ, type, nr, size)
    def self.iow(type, nr, size)  = ioc(WRITE, type, nr, size)

    # struct v4l2_capability { u8 driver[16]; u8 card[32]; u8 bus_info[32];
    #   u32 version; u32 capabilities; u32 device_caps; u32 reserved[3]; }
    CAPABILITY_SIZE = 104

    # struct v4l2_queryctrl { u32 id; u32 type; u8 name[32]; s32 min; s32 max;
    #   s32 step; s32 default; u32 flags; u32 reserved[2]; }
    QUERYCTRL_SIZE = 68

    # struct v4l2_control { u32 id; s32 value; }
    CONTROL_SIZE = 8

    # struct v4l2_format { u32 type; u8 pad[4]; union fmt[200]; } (8-aligned union)
    FORMAT_SIZE = 208

    # struct v4l2_requestbuffers { u32 count; u32 type; u32 memory;
    #   u32 capabilities; u8 flags; u8 reserved[3]; }
    REQUESTBUFFERS_SIZE = 20

    # struct v4l2_buffer (64-bit): u32 index,type,bytesused,flags,field; pad4;
    #   timeval(16); v4l2_timecode(16); u32 sequence,memory; union m(8);
    #   u32 length,reserved2,request_fd; pad4;
    BUFFER_SIZE = 88

    # struct v4l2_streamparm { u32 type; union parm[200]; }
    STREAMPARM_SIZE = 204

    V = 'V'
    VIDIOC_QUERYCAP  = ior(V, 0, CAPABILITY_SIZE)
    VIDIOC_G_FMT     = iowr(V, 4, FORMAT_SIZE)
    VIDIOC_S_FMT     = iowr(V, 5, FORMAT_SIZE)
    VIDIOC_REQBUFS   = iowr(V, 8, REQUESTBUFFERS_SIZE)
    VIDIOC_QUERYBUF  = iowr(V, 9, BUFFER_SIZE)
    VIDIOC_QBUF      = iowr(V, 15, BUFFER_SIZE)
    VIDIOC_DQBUF     = iowr(V, 17, BUFFER_SIZE)
    VIDIOC_STREAMON  = iow(V, 18, 4)
    VIDIOC_STREAMOFF = iow(V, 19, 4)
    VIDIOC_G_PARM    = iowr(V, 21, STREAMPARM_SIZE)
    VIDIOC_S_PARM    = iowr(V, 22, STREAMPARM_SIZE)
    VIDIOC_G_CTRL    = iowr(V, 27, CONTROL_SIZE)
    VIDIOC_S_CTRL    = iowr(V, 28, CONTROL_SIZE)
    VIDIOC_QUERYCTRL = iowr(V, 36, QUERYCTRL_SIZE)
  end
end
