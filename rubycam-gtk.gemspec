# frozen_string_literal: true

require_relative "lib/rubycam/version"

Gem::Specification.new do |spec|
  spec.name = "rubycam-gtk"
  spec.version = Rubycam::VERSION
  spec.authors = ["Nathan Kidd"]
  spec.email = ["nathankidd@hey.com"]

  spec.summary = "GTK4 viewer for Rubycam webcams (OBSBOT Tiny live preview and controls)"

  spec.description = <<~DESC
    A GTK4 desktop viewer built on the rubycam library: live video preview,
    sliders for gimbal/zoom/image controls, and a full OBSBOT Tiny control
    panel — privacy sleep/wake, AI tracking modes, gimbal presets, tracking
    speed, HDR, exposure modes and a raw-hex debug console.
  DESC

  spec.homepage = "https://github.com/ruby-gtk-project/rubycam"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # The rubycam-gtk gem ships only the viewer; the library itself comes from
  # the rubycam runtime dependency below.
  spec.files = `git ls-files -z`.split("\x0").select do |f|
    f.start_with?("lib/rubycam/gtk") ||
      f == "exe/rubycam-gtk" ||
      f == "rubycam-gtk.gemspec" ||
      %w[README.md LICENSE].include?(f)
  end
  spec.bindir = "exe"
  spec.executables = ["rubycam-gtk"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rubycam", Rubycam::VERSION
  spec.add_dependency "gtk4", "~> 4.2"
  spec.add_dependency "gdk_pixbuf2", "~> 4.2"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.21"
end
