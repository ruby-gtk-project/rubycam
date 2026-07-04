# frozen_string_literal: true

require_relative "lib/rubycam/version"

Gem::Specification.new do |spec|
  spec.name = "rubycam"
  spec.version = Rubycam::VERSION
  spec.authors = ["Nathan Kidd"]
  spec.email = ["nathankidd@hey.com"]

  spec.summary = "Pure-Ruby V4L2 webcam library and CLI, with OBSBOT Tiny support"

  spec.description = <<~DESC
    Rubycam is a pure-Ruby V4L2 library for controlling webcams and capturing
    MJPG/YUYV frames, plus a dry-cli command-line tool. It includes a vendor
    extension driver for OBSBOT Tiny cameras: privacy sleep/wake, AI tracking
    modes, gimbal presets, tracking speed, HDR and exposure control. The GTK4
    desktop viewer ships separately as the rubycam-gtk gem.
  DESC

  spec.homepage = "https://github.com/ruby-gtk-project/rubycam"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The rubycam gem is the library + CLI. The GTK viewer (lib/rubycam/gtk)
  # is the separate rubycam-gtk gem; dev-only files are left out.
  spec.files = `git ls-files -z`.split("\x0").select do |f|
    (f.start_with?("lib/rubycam") && !f.start_with?("lib/rubycam/gtk") && !f.end_with?(".erb")) ||
      f == "exe/rubycam" ||
      f == "rubycam.gemspec" ||
      %w[README.md LICENSE TINY4LINUX_FEATURES.md].include?(f)
  end
  spec.bindir = "exe"
  spec.executables = ["rubycam"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dry-cli", "~> 1.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.21"
end
