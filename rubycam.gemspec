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

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # The rubycam gem is the library + CLI: everything except the GTK viewer
  # (which is the separate rubycam-gtk gem) and dev-only files.
  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.start_with?("test/", "examples/", "lib/rubycam/gtk") ||
      f == "exe/rubycam-gtk" ||
      f.start_with?("rubycam-gtk.gemspec")
  end
  spec.bindir = "exe"
  spec.executables = ["rubycam"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dry-cli", "~> 1.0"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.21"
end
