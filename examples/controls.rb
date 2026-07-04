#!/usr/bin/env ruby
# List controls, or get/set one:
#   ruby examples/controls.rb                 # list everything
#   ruby examples/controls.rb zoom_absolute    # read a control
#   ruby examples/controls.rb zoom_absolute 50 # set a control
require_relative '../lib/rubycam'

Rubycam::Device.open('/dev/video0') do |cam|
  case ARGV.length
  when 0 then cam.controls.each_value { |c| puts c }
  when 1 then puts cam[ARGV[0].to_sym]
  else
    cam[ARGV[0].to_sym] = Integer(ARGV[1])
    puts "#{ARGV[0]} = #{cam[ARGV[0].to_sym]}"
  end
end
