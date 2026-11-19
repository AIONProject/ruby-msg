# frozen_string_literal: true

require 'minitest/autorun'
require 'time'
require_relative '../../../lib/mapi/convert/date_module'

module Mapi
  # A minimal host class that includes DateModule, mirroring how
  # Mapi::Message and Mapi::Msg consume the module in note-mime.rb.
  class TestHost
    include ::Mapi::DateModule
  end

  class TestDateModule < Minitest::Test
    # ---------------------------------------------------------------------------
    # helpers
    # ---------------------------------------------------------------------------

    def subject
      @subject ||= TestHost.new
    end

    # Convenience: parse an RFC 2822 string and return only the date+time fields
    # so that we can compare without worrying about timezone label differences.
    def parse_rfc2822(str)
      Time.rfc2822(str)
    end

    # ---------------------------------------------------------------------------
    # #to_rfc2822 — primary happy paths
    # ---------------------------------------------------------------------------

    # The module is included correctly and the method is publicly reachable.
    def test_module_included_exposes_to_rfc2822
      assert_respond_to subject, :to_rfc2822
    end

    # A plain Ruby Time object already responds to #rfc2822 natively.
    # DateModule should fall through to the rescue branch and call time.rfc2822.
    def test_plain_time_object_returns_valid_rfc2822
      time = Time.utc(2007, 1, 15, 0, 48, 19)
      result = subject.to_rfc2822(time)

      assert_kind_of String, result
      parsed = parse_rfc2822(result)
      assert_equal time.to_i, parsed.to_i, "Timestamps should round-trip correctly"
    end

    # A DateTime object stringifies to ISO 8601 via #to_s, so the primary
    # Time.iso8601 path should succeed.
    def test_datetime_object_via_iso8601_path
      require 'date'
      dt = DateTime.new(2024, 6, 15, 10, 30, 0)
      result = subject.to_rfc2822(dt)

      assert_kind_of String, result
      parsed = parse_rfc2822(result)
      assert_equal dt.year,  parsed.year
      assert_equal dt.month, parsed.month
      assert_equal dt.day,   parsed.day
      assert_equal dt.hour,  parsed.hour
      assert_equal dt.min,   parsed.min
    end

    # A Date object (date-only, no time) also goes through the rescue branch
    # because Date#to_s produces "YYYY-MM-DD", which Time.iso8601 rejects.
    def test_date_object_falls_back_to_rfc2822_method
      require 'date'
      d = Date.new(2023, 3, 1)
      # Date#rfc2822 should succeed; result must be parseable.
      result = subject.to_rfc2822(d)

      assert_kind_of String, result
      parsed = parse_rfc2822(result)
      assert_equal d.year,  parsed.year
      assert_equal d.month, parsed.month
      assert_equal d.day,   parsed.day
    end

    # An object whose #to_s returns a valid ISO 8601 datetime string goes through
    # the primary Time.iso8601 path without hitting the rescue branch.
    def test_iso8601_string_duck_type_via_to_s
      # Use explicit method bodies — avoids endless-method syntax (def m = expr)
      # inside a Struct block, which is unambiguous from Ruby 3.1 through 3.4.
      iso_wrapper = Struct.new(:value) do
        def to_s; value; end
        def rfc2822; raise "Should not reach rfc2822"; end
      end

      wrapper = iso_wrapper.new("2022-11-19T05:30:00Z")
      result = subject.to_rfc2822(wrapper)

      assert_kind_of String, result
      parsed = parse_rfc2822(result)
      assert_equal 2022, parsed.year
      assert_equal 11,   parsed.month
      assert_equal 19,   parsed.day
      assert_equal 5,    parsed.hour
      assert_equal 30,   parsed.min
    end

    # ---------------------------------------------------------------------------
    # #to_rfc2822 — edge cases around the rescue branch
    # ---------------------------------------------------------------------------

    # When Time.iso8601 raises ArgumentError (bad ISO 8601), the rescue branch
    # delegates to #rfc2822 on the original object.  Verify the delegation happens.
    def test_rescue_branch_calls_rfc2822_on_original_object
      expected_str = "Mon, 19 Nov 2007 00:48:19 +0000"

      # Use define_singleton_method instead of endless singleton-method syntax
      # (def obj.m = expr) for unambiguous compatibility from Ruby 3.1 onward.
      fake_time = Object.new
      fake_time.define_singleton_method(:to_s)   { "not-an-iso8601-string" }
      fake_time.define_singleton_method(:rfc2822) { "Mon, 19 Nov 2007 00:48:19 +0000" }

      result = subject.to_rfc2822(fake_time)
      assert_equal expected_str, result
    end

    # Verify that the rescue branch is *not* swallowing other exception types —
    # only ArgumentError is caught.  An object whose #rfc2822 raises RuntimeError
    # after the ArgumentError in iso8601 should propagate the RuntimeError.
    def test_non_argument_error_from_rfc2822_propagates
      bad_time = Object.new
      bad_time.define_singleton_method(:to_s)   { "also-invalid" }
      bad_time.define_singleton_method(:rfc2822) { raise RuntimeError, "unexpected error" }

      assert_raises(RuntimeError) { subject.to_rfc2822(bad_time) }
    end

    # ---------------------------------------------------------------------------
    # Timezone / UTC correctness
    # ---------------------------------------------------------------------------

    # RFC 2822 output for a UTC time should contain a recognisable timezone
    # offset string (+0000 or -0000 or UTC).
    def test_utc_time_produces_zero_offset_in_result
      time = Time.utc(2020, 5, 10, 12, 0, 0)
      result = subject.to_rfc2822(time)

      assert_match(/([\+\-]0000|UTC)/, result,
        "Expected RFC 2822 string to include a UTC offset, got: #{result}")
    end

    # ---------------------------------------------------------------------------
    # Integration: module included in a subclass mirrors note-mime.rb usage
    # ---------------------------------------------------------------------------

    # In note-mime.rb, Mapi::Msg also includes DateModule (line 266).
    # Confirm the include works in an inheritance chain without conflicts.
    def test_module_usable_in_subclass
      subclass = Class.new(TestHost) do
        include ::Mapi::DateModule
      end

      instance = subclass.new
      time = Time.utc(2015, 8, 20, 9, 15, 0)
      result = instance.to_rfc2822(time)
      assert_kind_of String, result
      assert_match /Aug/, result
    end

    # ---------------------------------------------------------------------------
    # Return-value shape
    # ---------------------------------------------------------------------------

    # The returned string must be parseable by Time.rfc2822 (i.e. it is a
    # well-formed RFC 2822 date-time string, not just any non-empty string).
    def test_return_value_is_parseable_rfc2822
      time = Time.utc(2000, 1, 1, 0, 0, 0)
      result = subject.to_rfc2822(time)

      assert_silent { parse_rfc2822(result) }
    end

    # Idempotency: calling to_rfc2822 twice on the same input returns equal strings.
    def test_idempotent_for_same_input
      time = Time.utc(2021, 12, 31, 23, 59, 59)
      assert_equal subject.to_rfc2822(time), subject.to_rfc2822(time)
    end
  end
end
