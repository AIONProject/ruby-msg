# frozen_string_literal: true

# Unit tests focused on DateModule usage inside Mapi::Message and Mapi::Msg
# as defined in lib/mapi/convert/note-mime.rb.
#
# Strategy
# --------
# Both classes have heavyweight dependencies (OLE storage, props, recipients,
# the full Mime parser).  Rather than loading all of that, we build minimal
# test doubles that satisfy only what populate_headers / to_rfc2822 touch,
# then open the real module under test through anonymous subclasses.
#
# Run:
#   ruby test/mapi/convert/note_mime_date_module_test.rb

require 'minitest/autorun'
require 'time'
require 'date'
require_relative '../../../lib/mapi/convert/date_module'
require_relative '../../../lib/mapi/mime'

# ---------------------------------------------------------------------------
# Shared doubles
# ---------------------------------------------------------------------------

# Minimal stand-in for Mapi::Mime — provides the headers hash used by
# populate_headers and checked by the Date-setting logic.
#
# Regular method bodies are used throughout (no endless `def m = expr` syntax)
# to stay unambiguous across Ruby 3.1–3.4.
FakeMime = Struct.new(:headers) do
  def multipart?; false; end
  def preamble;   +'';   end
end

# Builds a FakeMime with an optional pre-existing Date header.
def make_mime(existing_date: nil)
  h = Hash.new { |hash, key| hash[key] = [] }
  h['Date'] = [existing_date] if existing_date
  FakeMime.new(h)
end

# ---------------------------------------------------------------------------
# Mapi::Message test double
# ---------------------------------------------------------------------------
# We replicate only the interface that populate_headers touches:
#   props.sender_addrtype, props.sender_name, props.sender_email_address,
#   props.message_delivery_time / client_submit_time /
#   last_modification_time / creation_time,
#   props.subject, recipients, and mime / headers.

module Mapi
  # Minimal props object whose time keys are configurable per test.
  FakeProps = Struct.new(
    :sender_addrtype, :sender_name, :sender_email_address,
    :message_delivery_time, :client_submit_time,
    :last_modification_time, :creation_time,
    :subject,
    :internet_message_id, :in_reply_to_id,
    :importance, :priority, :sensitivity,
    :conversation_topic, :read_receipt_requested,
    keyword_init: true
  )

  # A concrete Message-like class that includes DateModule and delegates
  # the minimum surface needed by populate_headers.
  class FakeMessage
    include ::Mapi::DateModule

    attr_reader :props, :recipients

    def initialize(props:, mime: make_mime, recipients: [])
      @props      = props
      @_mime      = mime
      @recipients = recipients
    end

    # Mirrors the real Message#mime / #headers interface.
    def mime;    @_mime;         end
    def headers; @_mime.headers; end

    # Copied verbatim from note-mime.rb lines 33-137 — we test *this* logic.
    def populate_headers
      name, email = props.sender_name, props.sender_email_address
      if props.sender_addrtype == 'SMTP'
        headers['From'] = if name && email && name != email
                            [%{"#{name}" <#{email}>}]
                          else
                            [email || name]
                          end
      elsif !headers.has_key?('From')
        if email
          user   = name ? name.sub(/(.*), (.*)/, "\\2.\\1") : email[/\w+$/].downcase
          domain = (email[%r{^/O=([^/]+)}i, 1].downcase + '.com' rescue email)
          headers['From'] = [name ? %{"#{name}" <#{user}@#{domain}>} : "<#{user}@#{domain}>"]
        elsif name
          headers['From'] = [%{"#{name}"}]
        end
      end

      recips_by_type = recipients.group_by { |r| r.type }
      [:to, :cc, :bcc].each do |type|
        recips = recips_by_type[type] || []
        headers[type.to_s.sub(/^(.)/) { $1.upcase }] = [recips.join(', ')] unless recips.empty?
      end
      headers['Subject'] = [props.subject] if props.subject

      # ── This is the DateModule-exercising block (note-mime.rb lines 98-112) ──
      if !headers.has_key?('Date')
        keys = %w[message_delivery_time client_submit_time last_modification_time creation_time]
        time = keys.each { |key| break time if time = props.send(key) }
        time = nil unless Date === time || Time === time

        headers['Date'] = [to_rfc2822(time)] if time
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mapi::FakeMsg — mirrors Mapi::Msg < Message (note-mime.rb lines 265-277)
  # ---------------------------------------------------------------------------
  # Msg overrides populate_headers: after calling super it falls back to
  # OLE dirent timestamps when no Date has been set yet.  We replace the OLE
  # traversal with a simple configurable list of times.
  class FakeMsgMessage < FakeMessage
    include ::Mapi::DateModule

    # +ole_times+ is an Array of Time / DateTime values simulating
    # @root.ole.dirents.map { |d| d.modify_time || d.create_time }
    def initialize(props:, mime: make_mime, recipients: [], ole_times: [])
      super(props: props, mime: mime, recipients: recipients)
      @ole_times = ole_times
    end

    def populate_headers
      super
      unless headers.has_key?('Date')
        time = @ole_times.compact.sort.last
        headers['Date'] = [to_rfc2822(time)] if time
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers shared by test classes
  # ---------------------------------------------------------------------------
  module TestHelpers
    def blank_props(**overrides)
      FakeProps.new(
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
  # Test suite 1 – Mapi::Message (note-mime.rb) DateModule usage
  # ===========================================================================
  class TestMessageDateModule < Minitest::Test
    include TestHelpers

    # ── include check ────────────────────────────────────────────────────────

    def test_message_includes_date_module
      assert_includes FakeMessage.ancestors, ::Mapi::DateModule
    end

    def test_message_responds_to_to_rfc2822
      msg = FakeMessage.new(props: blank_props)
      assert_respond_to msg, :to_rfc2822
    end

    # ── Date header set from message_delivery_time (highest priority) ────────

    def test_date_header_set_from_message_delivery_time
      t = Time.utc(2024, 3, 10, 8, 0, 0)
      props = blank_props(message_delivery_time: t)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      assert msg.headers.has_key?('Date'), 'Date header should be set'
      assert valid_rfc2822?(msg.headers['Date'].first),
             "Date header should be a valid RFC 2822 string"
      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal t.to_i, parsed.to_i
    end

    # ── Fallback chain: client_submit_time used when delivery_time absent ─────

    def test_date_header_falls_back_to_client_submit_time
      t = Time.utc(2023, 7, 4, 12, 30, 0)
      props = blank_props(client_submit_time: t)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal t.to_i, parsed.to_i
    end

    # ── Fallback chain: last_modification_time ───────────────────────────────

    def test_date_header_falls_back_to_last_modification_time
      t = Time.utc(2022, 1, 1, 0, 0, 0)
      props = blank_props(last_modification_time: t)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal t.to_i, parsed.to_i
    end

    # ── Fallback chain: creation_time (lowest priority) ──────────────────────

    def test_date_header_falls_back_to_creation_time
      t = Time.utc(2021, 6, 15, 18, 45, 0)
      props = blank_props(creation_time: t)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal t.to_i, parsed.to_i
    end

    # ── Priority: delivery_time beats all others when multiple are set ────────

    def test_message_delivery_time_has_priority_over_other_times
      delivery_time = Time.utc(2024, 1, 1, 0, 0, 0)
      submit_time   = Time.utc(2024, 6, 1, 0, 0, 0)
      props = blank_props(
        message_delivery_time: delivery_time,
        client_submit_time:    submit_time
      )
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal delivery_time.to_i, parsed.to_i,
                   'message_delivery_time should take precedence'
    end

    # ── No date header when all time props are nil ───────────────────────────

    def test_no_date_header_when_all_time_props_nil
      msg = FakeMessage.new(props: blank_props)
      msg.populate_headers

      refute msg.headers.has_key?('Date'),
             'Date header should not be set when no time props exist'
    end

    # ── Non-Date objects are excluded (time = nil unless Date === time) ───────

    def test_non_date_object_does_not_set_date_header
      # Only a bare Integer — not a Date/Time — is returned by props.
      fake_non_date = 1_234_567_890  # Fixnum, not a Date
      props = blank_props(message_delivery_time: fake_non_date)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      refute msg.headers.has_key?('Date'),
             'Date header should not be set for a non-Date time value'
    end

    # ── Existing Date header is not overwritten ───────────────────────────────

    def test_existing_date_header_is_preserved
      original = 'Mon, 01 Jan 2024 00:00:00 +0000'
      mime  = make_mime(existing_date: original)
      props = blank_props(message_delivery_time: Time.utc(2025, 5, 5))
      msg = FakeMessage.new(props: props, mime: mime)
      msg.populate_headers

      assert_equal [original], msg.headers['Date'],
                   'An existing Date header must not be overwritten'
    end

    # ── DateTime (ISO 8601 path through DateModule) ───────────────────────────

    def test_datetime_prop_produces_valid_date_header
      dt = DateTime.new(2023, 11, 19, 10, 30, 0)
      props = blank_props(message_delivery_time: dt)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first),
             "Expected valid RFC 2822 from DateTime prop"
    end

    # ── Date (date-only object, falls through to rescue in DateModule) ────────

    def test_date_only_prop_produces_valid_date_header
      d = Date.new(2020, 8, 15)
      props = blank_props(message_delivery_time: d)
      msg = FakeMessage.new(props: props)
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first),
             "Expected valid RFC 2822 from Date prop"
    end

    # ── to_rfc2822 called directly on the Message instance ───────────────────

    def test_to_rfc2822_accessible_on_message_instance
      msg    = FakeMessage.new(props: blank_props)
      time   = Time.utc(2000, 6, 1, 12, 0, 0)
      result = msg.to_rfc2822(time)

      assert valid_rfc2822?(result)
      assert_equal time.to_i, Time.rfc2822(result).to_i
    end

    # ── populate_headers is idempotent for the Date header ───────────────────

    def test_populate_headers_idempotent_for_date
      t = Time.utc(2024, 9, 9, 9, 9, 9)
      props = blank_props(message_delivery_time: t)
      msg = FakeMessage.new(props: props)

      msg.populate_headers
      first_date = msg.headers['Date'].dup

      msg.populate_headers      # second call must not change the value
      assert_equal first_date, msg.headers['Date']
    end
  end

  # ===========================================================================
  # Test suite 2 – Mapi::Msg (note-mime.rb subclass) DateModule usage
  # ===========================================================================
  class TestMsgDateModule < Minitest::Test
    include TestHelpers

    # ── include check ────────────────────────────────────────────────────────

    def test_msg_includes_date_module
      assert_includes FakeMsgMessage.ancestors, ::Mapi::DateModule
    end

    # ── OLE fallback: Date is set from dirent times when props have none ──────

    def test_date_set_from_ole_dirent_when_props_empty
      ole_time = Time.utc(2022, 4, 20, 14, 0, 0)
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [ole_time])
      msg.populate_headers

      assert msg.headers.has_key?('Date'),
             'Date header should be set from OLE dirent time'
      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal ole_time.to_i, parsed.to_i
    end

    # ── OLE fallback picks the LATEST dirent time ─────────────────────────────

    def test_date_uses_most_recent_ole_dirent_time
      older  = Time.utc(2020, 1, 1)
      newer  = Time.utc(2023, 12, 31)
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [older, newer])
      msg.populate_headers

      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal newer.to_i, parsed.to_i,
                   'Should pick the most recent OLE dirent time'
    end

    # ── Props take priority over OLE dirents (super sets Date first) ──────────

    def test_props_time_takes_priority_over_ole_dirent
      props_time = Time.utc(2024, 6, 15, 10, 0, 0)
      ole_time   = Time.utc(2024, 7, 20, 10, 0, 0)  # later but should be ignored

      props = blank_props(message_delivery_time: props_time)
      msg   = FakeMsgMessage.new(props: props, ole_times: [ole_time])
      msg.populate_headers

      parsed = Time.rfc2822(msg.headers['Date'].first)
      assert_equal props_time.to_i, parsed.to_i,
                   'Props time should take priority over OLE dirent time'
    end

    # ── Existing Date header survives through Msg#populate_headers too ────────

    def test_existing_date_header_not_overwritten_in_msg
      original = 'Fri, 01 Jan 2021 00:00:00 +0000'
      mime  = make_mime(existing_date: original)
      props = blank_props
      msg   = FakeMsgMessage.new(props: props, mime: mime,
                                 ole_times: [Time.utc(2024, 1, 1)])
      msg.populate_headers

      assert_equal [original], msg.headers['Date'],
                   'Existing Date header must survive Msg#populate_headers'
    end

    # ── No Date header set when both props and OLE times are absent ───────────

    def test_no_date_header_when_props_and_ole_empty
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [])
      msg.populate_headers

      refute msg.headers.has_key?('Date')
    end

    # ── nil values in OLE times are compacted away ────────────────────────────

    def test_ole_nil_times_are_ignored
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [nil, nil])
      msg.populate_headers

      refute msg.headers.has_key?('Date'),
             'nil OLE dirent times must not produce a Date header'
    end

    # ── OLE time produces a valid RFC 2822 string via to_rfc2822 ─────────────

    def test_ole_time_date_header_is_valid_rfc2822
      ole_time = Time.utc(2019, 3, 15, 7, 30, 0)
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [ole_time])
      msg.populate_headers

      assert valid_rfc2822?(msg.headers['Date'].first),
             "OLE dirent time must produce a valid RFC 2822 Date header"
    end

    # ── DateTime OLE time (ISO 8601 path through DateModule) ─────────────────

    def test_datetime_ole_time_produces_valid_date_header
      dt = DateTime.new(2018, 11, 5, 16, 0, 0)
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [dt])
      msg.populate_headers

      assert msg.headers.has_key?('Date')
      assert valid_rfc2822?(msg.headers['Date'].first)
    end

    # ── Msg#to_rfc2822 is reachable on the Msg instance directly ─────────────

    def test_to_rfc2822_accessible_on_msg_instance
      msg    = FakeMsgMessage.new(props: blank_props)
      time   = Time.utc(2010, 10, 10, 10, 10, 10)
      result = msg.to_rfc2822(time)

      assert valid_rfc2822?(result)
      assert_equal time.to_i, Time.rfc2822(result).to_i
    end

    # ── OLE fallback idempotency ──────────────────────────────────────────────

    def test_populate_headers_idempotent_in_msg
      ole_time = Time.utc(2017, 7, 7, 7, 7, 7)
      msg = FakeMsgMessage.new(props: blank_props, ole_times: [ole_time])

      msg.populate_headers
      first_date = msg.headers['Date'].dup

      msg.populate_headers
      assert_equal first_date, msg.headers['Date']
    end
  end
end
