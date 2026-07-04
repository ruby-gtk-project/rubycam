# Rubycam: pure-Ruby V4L2 webcam library (controls + MJPG/YUYV capture).
#
#   Rubycam::Device.open('/dev/video0') do |cam|
#     cam[:zoom_absolute] = 50
#     cam.set_format(width: 1920, height: 1080, pixel_format: 'MJPG')
#     File.binwrite('frame.jpg', cam.capture_frame)
#   end
require_relative 'rubycam/version'
require_relative 'rubycam/ioctl'
require_relative 'rubycam/controls'
require_relative 'rubycam/device'
require_relative 'rubycam/obsbot'

module Rubycam
  # All /dev/video* nodes that are actual capture devices.
  def self.devices
    Dir['/dev/video*'].sort.filter_map do |path|
      Device.open(path)
    rescue SystemCallError
      nil
    end
  end
end
