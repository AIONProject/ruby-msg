module Mapi
  module DateModule
    def to_rfc2822(time)
      begin
        Time.iso8601(time.to_s).rfc2822
      rescue ArgumentError => _error
        time.rfc2822
      end
    end
  end
end
