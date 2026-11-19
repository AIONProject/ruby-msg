# frozen_string_literal: true

# Unit tests focused on DateModule usage inside Mapi::Message and Mapi::Msg
# as defined in lib/mapi/convert/note-tmail.rb.
#
# note-tmail.rb mirrors note-mime.rb's populate_headers structure exactly:
#   - Mapi::Message includes DateModule and calls to_rfc2822 for Date header
#   - Mapi::Msg < Message also includes DateModule and falls back to OLE times
#
# Because note-tmail.rb requires the external 'tmail' gem, we do NOT require
# that file directly.  Instead we pull in only the two modules under test
# (DateModule and the shared Mime class) and replicate the exact Date-related
# logic in controlled test doubles — the same technique used for note-mime.rb.
#
# Run:
#   ruby test/mapi/convert/note_tmail_date_module_test.rb

require 'minitest/autorun'
require 'time'
require 'date'
require_relative '../../../lib/mapi/convert/date_module'
require_relative '../../../lib/mapi/mime'

# ---------------------------------------------------------------------------
# Lightweight doubles (tmail-flavoured naming)
# ---------------------------------------------------------------------------

# Simulates the headers hash populated by populate_headers in note-tmail.rb.
# TMail stores headers differently from Mime but the Date-setting code path
# is identical, so a plain Hash with default [] suffices for testing.
def make_tmail_headers(existing_date: nil)
  h = Hash.new { |hash, key| hash[key] = [] }
  h['Date'] = [existing_date] if existing_date
  h
end

module Mapi
  # Minimal props used by both Message and Msg in note-tmail.rb
  TMailFakeProps = Struct.new(
    :sender_addrtype, :sender_name, :sender_email_address,
    :message_delivery_time, :client_submit_time,
    :last_modification_time, :creation_time,
    :subject,
    :internet_message_id, :in_reply_to_id,
    :importance, :priority, :sensitivity,
    :conversation_topic, :read_receipt_requested,
    keyword_init: true
  )

  # ---------------------------------------------------------------------------
  # Replicates the Date-related portion of Mapi::Message#populate_headers
  # from note-tmail.rb (lines 108-122), verbatim.
  # ---------------------------------------------------------------------------
  class TMailFakeMessage
    include ::Mapi::DateModule

    attr_reader :props, :recipients

    def initialize(props:, headers: make_tmail_headers, recipients: [])
      @props      = props
      @headers    = headers
      @recipients = recipients
    end

    def headers; @headers; end

    # Exact copy of the Date-setting block from note-tmail.rb lines 108-122.
    def populate_headers
      if !headers.has_key?('Date')
        keys = %w[message_delivery_time client_submit_time last_modification_time creation_time]
        time = keys.each { |key| break time if time = props.send(key) }
        time = nil unless Date === time || Time === time

        headers['Date'] = [to_rfc2822(time)] if time
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mirrors Mapi::Msg < Message from note-tmail.rb (lines 278-290).
  # ---------------------------------------------------------------------------
  class TMailFakeMsgMessage < TMailFakeMessage
    include ::Mapi::DateModule

    def initialize(props:, headers: make_tmail_headers, recipients: [], ole_times: [])
      super(props: props, headers: headers, recipients: recipients)
      @ole_times = ole_times
    end

    # Exact copy of note-tmail.rb Msg#populate_headers.
    def populate_headers
      super
      unless headers.has_key?('Date')
        time = @ole_times.compact.sort.last
        headers['Date'] = [to_rfc2822(time)] if time
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helper
  # ---------------------------------------------------------------------------
  module TMailTestHelpers
    def blank_props(**overrides)
      TMailFakeProps.new(
        sender_addrtype: nil, sender_name: nil, sender_email_address: nil,
        message_delivery_time: nil, client_submit_time: nil,
        last_modification_time: nil, creation_time: nil,
        subject: nil, internet_message_id: nil, in_reply_to_id: nil,
        importance: nil, priority: nil, sensitivity: nil,
        conversation_topic: nil, read_receipt_requested: nil,
        **overrides
      )
    end

    def valid_rfc2822?(str)
      Time.rfc2822(str)
      true
    rescue ArgumentError
      false
    end
  end

  # ===========================================================================
  # Test suite 1 – note-tmail.rb : Mapi::Message DateModule usage
  # ===========================================================================
  class TestTMailMessageDateModule < Minitest::Test
    include TMailTestHelpers

    # ── include sanity ───────────────────────────────────────────────────────

    def test_message_includes_date_module
      assert_includes TMailFakeMessage.ancestors, ::Mapi::DateModule
    end

    def test_message_responds_to_to_rfc2822
      assert_respond_to TMailFakeMessage.new(props: blank_props), :to_rfc2822
    end

    # ── Date header set from message_delivery_time ────────────────────────────

    def test_date_header_set_from_message_delivery_time
      t     = Time.utc(2024, 3, 10, 8, 0, 0)
      msg   = TMailFakeMessage.new(props: blank_props(message_delivery_time: t))
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first)
      assert_equal t.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── Fallback to client_submit_time ───────────────────────────────────────

    def test_date_falls_back_to_client_submit_time
      t   = Time.utc(2023, 7, 4, 12, 30, 0)
      msg = TMailFakeMessage.new(props: blank_props(client_submit_time: t))
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert_equal t.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── Fallback to last_modification_time ───────────────────────────────────

    def test_date_falls_back_to_last_modification_time
      t   = Time.utc(2022, 1, 1)
      msg = TMailFakeMessage.new(props: blank_props(last_modification_time: t))
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert_equal t.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── Fallback to creation_time ─────────────────────────────────────────────

    def test_date_falls_back_to_creation_time
      t   = Time.utc(2021, 6, 15, 18, 45, 0)
      msg = TMailFakeMessage.new(props: blank_props(creation_time: t))
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert_equal t.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── Priority: message_delivery_time beats client_submit_time ─────────────

    def test_message_delivery_time_wins_over_client_submit_time
      delivery = Time.utc(2024, 1, 1)
      submit   = Time.utc(2024, 6, 1)
      msg = TMailFakeMessage.new(
        props: blank_props(message_delivery_time: delivery,
                           client_submit_time:    submit)
      )
      msg.populate_headers

      assert_equal delivery.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── No Date when all time props are nil ──────────────────────────────────

    def test_no_date_header_when_all_time_props_nil
      msg = TMailFakeMessage.new(props: blank_props)
      msg.populate_headers
      refute msg.headers.has_key?('Date')
    end

    # ── Non-Date objects are excluded (guard: Date === time) ─────────────────

    def test_non_date_object_does_not_set_date_header
      msg = TMailFakeMessage.new(
        props: blank_props(message_delivery_time: 1_234_567_890)
      )
      msg.populate_headers
      refute msg.headers.has_key?('Date')
    end

    # ── Existing Date header is not overwritten ───────────────────────────────

    def test_existing_date_header_is_preserved
      original = 'Mon, 01 Jan 2024 00:00:00 +0000'
      headers  = make_tmail_headers(existing_date: original)
      msg = TMailFakeMessage.new(
        props:   blank_props(message_delivery_time: Time.utc(2025, 5, 5)),
        headers: headers
      )
      msg.populate_headers

      assert_equal [original], msg.headers['Date']
    end

    # ── DateTime (ISO 8601 path through DateModule) ───────────────────────────

    def test_datetime_prop_produces_valid_date_header
      dt  = DateTime.new(2023, 11, 19, 10, 30, 0)
      msg = TMailFakeMessage.new(props: blank_props(message_delivery_time: dt))
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first)
    end

    # ── Date (date-only object falls to rescue in DateModule) ─────────────────

    def test_date_only_prop_produces_valid_date_header
      d   = Date.new(2020, 8, 15)
      msg = TMailFakeMessage.new(props: blank_props(message_delivery_time: d))
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first)
    end

    # ── to_rfc2822 callable directly on a Message instance ───────────────────

    def test_to_rfc2822_accessible_on_instance
      msg    = TMailFakeMessage.new(props: blank_props)
      time   = Time.utc(2000, 6, 1, 12, 0, 0)
      result = msg.to_rfc2822(time)

      assert valid_rfc2822?(result)
      assert_equal time.to_i, Time.rfc2822(result).to_i
    end

    # ── Idempotency: second populate_headers call does not change Date ────────

    def test_populate_headers_idempotent_for_date
      t   = Time.utc(2024, 9, 9, 9, 9, 9)
      msg = TMailFakeMessage.new(props: blank_props(message_delivery_time: t))

      msg.populate_headers
      first_date = msg.headers['Date'].dup

      msg.populate_headers
      assert_equal first_date, msg.headers['Date']
    end

    # ── RFC 2822 output for a UTC time contains a recognisable UTC offset ─────

    def test_utc_date_header_contains_zero_offset
      t   = Time.utc(2020, 5, 10, 12, 0, 0)
      msg = TMailFakeMessage.new(props: blank_props(message_delivery_time: t))
      msg.populate_headers

      assert_match(/([\+\-]0000|UTC)/, msg.headers['Date'].first)
    end
  end

  # ===========================================================================
  # Test suite 2 – note-tmail.rb : Mapi::Msg DateModule usage
  # ===========================================================================
  class TestTMailMsgDateModule < Minitest::Test
    include TMailTestHelpers

    # ── include sanity ───────────────────────────────────────────────────────

    def test_msg_includes_date_module
      assert_includes TMailFakeMsgMessage.ancestors, ::Mapi::DateModule
    end

    # ── OLE fallback: Date set from dirent time when props have none ──────────

    def test_date_set_from_ole_dirent_when_props_empty
      ole_time = Time.utc(2022, 4, 20, 14, 0, 0)
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [ole_time])
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert_equal ole_time.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── OLE fallback picks the LATEST dirent time ─────────────────────────────

    def test_date_uses_most_recent_ole_dirent
      older = Time.utc(2020, 1, 1)
      newer = Time.utc(2023, 12, 31)
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [older, newer])
      msg.populate_headers

      assert_equal newer.to_i, Time.rfc2822(msg.headers['Date'].first).to_i
    end

    # ── Props take priority over OLE dirents ──────────────────────────────────

    def test_props_time_takes_priority_over_ole_dirent
      props_time = Time.utc(2024, 6, 15, 10, 0, 0)
      ole_time   = Time.utc(2024, 7, 20, 10, 0, 0)
      msg = TMailFakeMsgMessage.new(
        props:     blank_props(message_delivery_time: props_time),
        ole_times: [ole_time]
      )
      msg.populate_headers

      assert_equal props_time.to_i, Time.rfc2822(msg.headers['Date'].first).to_i,
                   'Props time must take priority over OLE dirent time'
    end

    # ── Existing Date header survives through Msg#populate_headers ────────────

    def test_existing_date_header_not_overwritten_in_msg
      original = 'Fri, 01 Jan 2021 00:00:00 +0000'
      headers  = make_tmail_headers(existing_date: original)
      msg = TMailFakeMsgMessage.new(
        props:     blank_props,
        headers:   headers,
        ole_times: [Time.utc(2024, 1, 1)]
      )
      msg.populate_headers

      assert_equal [original], msg.headers['Date']
    end

    # ── No Date when both props and OLE times are absent ─────────────────────

    def test_no_date_header_when_props_and_ole_empty
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [])
      msg.populate_headers
      refute msg.headers.has_key?('Date')
    end

    # ── nil OLE times are compacted away ─────────────────────────────────────

    def test_ole_nil_times_are_ignored
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [nil, nil])
      msg.populate_headers
      refute msg.headers.has_key?('Date')
    end

    # ── OLE date header is a valid RFC 2822 string ────────────────────────────

    def test_ole_dirent_produces_valid_rfc2822_date_header
      ole_time = Time.utc(2019, 3, 15, 7, 30, 0)
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [ole_time])
      msg.populate_headers

      assert valid_rfc2822?(msg.headers['Date'].first)
    end

    # ── DateTime OLE time (ISO 8601 path through DateModule) ─────────────────

    def test_datetime_ole_time_produces_valid_date_header
      dt = DateTime.new(2018, 11, 5, 16, 0, 0)
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [dt])
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first)
    end

    # ── to_rfc2822 callable directly on a Msg instance ───────────────────────

    def test_to_rfc2822_accessible_on_msg_instance
      msg    = TMailFakeMsgMessage.new(props: blank_props)
      time   = Time.utc(2010, 10, 10, 10, 10, 10)
      result = msg.to_rfc2822(time)

      assert valid_rfc2822?(result)
      assert_equal time.to_i, Time.rfc2822(result).to_i
    end

    # ── OLE fallback idempotency ──────────────────────────────────────────────

    def test_populate_headers_idempotent_in_msg
      ole_time = Time.utc(2017, 7, 7, 7, 7, 7)
      msg = TMailFakeMsgMessage.new(props: blank_props, ole_times: [ole_time])

      msg.populate_headers
      first_date = msg.headers['Date'].dup

      msg.populate_headers
      assert_equal first_date, msg.headers['Date']
    end
  end
end
