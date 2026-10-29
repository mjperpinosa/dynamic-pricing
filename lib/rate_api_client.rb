class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  # Timeouts for a slow or hanging call
  open_timeout 1
  read_timeout 3
  write_timeout 1

  # Errors raise by failed calls to the RateAPI
  class Error < StandardError; end
  class TimeoutError < Error; end         # no response in time
  class ConnectionError < Error; end      # could not connect, or the connection broke
  class TooManyRequestsError < Error; end # HTTP 429: the token's daily quota is used up!
  class ResponseError < Error; end        # any other response we can't use

  BODY_PREVIEW_LENGTH = 200

  # Sends all the attributes ({ period:, hotel:, room: } hashes) in one POST /pricing.
  def self.get_rates(attributes)
    response = self.post("/pricing", body: { attributes: attributes }.to_json)
    parse_rates(response, attributes)
  rescue Timeout::Error, Errno::ETIMEDOUT => e
    raise TimeoutError, "no response in time (#{e.class})"
  rescue SocketError, SystemCallError, IOError => e
    raise ConnectionError, "connection failed (#{e.class}: #{e.message})"
  end

  def self.parse_rates(response, attributes)
    failure = ->(problem) { "#{problem} (HTTP #{response.code}): #{body_preview(response)}" }
    raise TooManyRequestsError, failure.("too many requests") if response.code == 429
    raise ResponseError, failure.("unexpected status") unless response.code.between?(200, 299)

    begin
      data = JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise ResponseError, failure.("body is not JSON")
    end
    entries = data["rates"] if data.is_a?(Hash)
    raise ResponseError, failure.("no rates array") unless entries.is_a?(Array)

    requested = attributes.index_by(&:itself)
    rates = {}
    entries.each do |entry|
      next unless entry.is_a?(Hash)

      attribute = requested[{ period: entry["period"], hotel: entry["hotel"], room: entry["room"] }]
      next if attribute.nil? || rates.key?(attribute)

      rate = parse_rate(entry["rate"])
      if rate.nil?
        raise ResponseError, failure.("invalid rate #{entry['rate'].inspect.truncate(40)} for #{label(attribute)}")
      end

      rates[attribute] = rate
    end

    missing = attributes.reject { |attribute| rates.key?(attribute) }
    if missing.any?
      raise ResponseError, failure.("no rate for #{missing.size} of #{attributes.size} combinations, e.g. #{label(missing.first)}")
    end
    rates
  end

  # parses rate and return null for invalid values
  def self.parse_rate(value)
    case value
    when Integer then value if value >= 0
    when /\A\d+\z/ then value.to_i
    end
  end

  # cleans up the response body for logging. remove invalid UTF-8, squish whitespace, truncate
  def self.body_preview(response)
    response.body.to_s.scrub.squish.truncate(BODY_PREVIEW_LENGTH)
  end

  # returns a string like "Summer/FloatingPointResort/SingletonRoom" for logging
  def self.label(attribute)
    attribute.values_at(:period, :hotel, :room).join("/")
  end

  private_class_method :parse_rates, :parse_rate, :body_preview, :label
end
