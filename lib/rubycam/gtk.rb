# frozen_string_literal: true

# Rubycam GTK4 viewer: live preview plus the full OBSBOT control panel.
# Depends on the rubycam gem for the underlying V4L2 / OBSBOT driver.
#
#   require "rubycam/gtk"
#   Rubycam::GTK::CameraApp.new("/dev/video0").build.run
require "gtk4"
require "rubycam"

require_relative "gtk/obsbot_panel"
require_relative "gtk/camera_app"
