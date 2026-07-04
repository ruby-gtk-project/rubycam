# frozen_string_literal: true

require "test_helper"

class RubycamTest < Minitest::Test
  def test_version_is_present
    assert_match(/\A\d+\.\d+\.\d+/, Rubycam::VERSION)
  end

  def test_devices_returns_an_array
    # No camera is required in CI; the enumeration must still be safe.
    assert_kind_of Array, Rubycam.devices
  end
end
