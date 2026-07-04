module Rubycam
  # A single camera control (brightness, zoom_absolute, ...) discovered via
  # VIDIOC_QUERYCTRL. Reading and writing goes through the owning device.
  class Control
    TYPES = { 1 => :integer, 2 => :boolean, 3 => :menu, 4 => :button,
              5 => :integer64, 6 => :ctrl_class, 7 => :string, 8 => :bitmask,
              9 => :integer_menu }.freeze

    FLAG_DISABLED  = 0x0001
    FLAG_GRABBED   = 0x0002
    FLAG_READ_ONLY = 0x0004
    FLAG_INACTIVE  = 0x0010

    attr_reader :id, :type, :name, :min, :max, :step, :default, :flags

    def initialize(device, id:, type:, name:, min:, max:, step:, default:, flags:)
      @device = device
      @id = id
      @type = TYPES.fetch(type, type)
      @name = name
      @min = min
      @max = max
      @step = step
      @default = default
      @flags = flags
    end

    # Symbol key derived from the control name, e.g. "Zoom, Absolute" => :zoom_absolute
    def key = @key ||= name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '').to_sym

    def value = @device.get_control(id)

    def value=(v)
      clamped = v.clamp(min, max)
      @device.set_control(id, clamped)
    end

    def inactive? = flags & FLAG_INACTIVE != 0
    def read_only? = flags & FLAG_READ_ONLY != 0

    def to_s
      "#{key} (#{type}) min=#{min} max=#{max} step=#{step} default=#{default} value=#{value}"
    end
  end
end
