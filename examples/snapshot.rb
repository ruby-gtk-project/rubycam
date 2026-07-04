#!/usr/bin/env ruby
# Capture a single JPEG frame: ruby examples/snapshot.rb [device] [output.jpg]
require_relative '../lib/rubycam'

Rubycam::Device.open(ARGV.fetch(0, '/dev/video0')) do |cam|
  cam.set_format(width: 1920, height: 1080, pixel_format: 'MJPG')
  ARGV.fetch(1, 'snapshot.jpg').then do |path|
    File.binwrite(path, cam.capture_frame)
    puts "#{cam.card}: wrote #{path}"
  end
end
