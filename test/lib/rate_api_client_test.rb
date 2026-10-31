require "test_helper"

# The real client against FakeRateApiServer, a local stand-in for rate-api.
class RateApiClientTest < ActiveSupport::TestCase
  ALL = PricingInventory::ALL

  test "sends all the combinations in one POST /pricing with the token" do
    with_fake_rate_api_server(status: 200, body: rates_body) do |server|
      RateApiClient.get_rates(ALL)

      assert_equal 1, server.requests.size
      request = server.requests.first
      assert_equal ["POST", "/pricing"], [request.http_method, request.path]
      assert_equal "application/json", request.headers["content-type"]
      assert_equal RateApiClient.headers["token"], request.headers["token"]
      assert_equal ALL.map(&:stringify_keys), JSON.parse(request.body)["attributes"]
    end
  end

  test "returns every requested combination with its rate as an integer" do
    with_fake_rate_api_server(status: 200, body: rates_body(rate: 15000)) do
      rates = RateApiClient.get_rates(ALL)

      assert_equal ALL.index_with(15000), rates
      assert rates.values.all?(Integer)
    end
  end

  test "converts rates sent as strings to integers" do
    with_fake_rate_api_server(status: 200, body: rates_body(rate: "15000")) do
      rates = RateApiClient.get_rates(ALL)

      assert_equal ALL.index_with(15000), rates
      assert rates.values.all?(Integer)
    end
  end

  test "ignores entries that weren't asked for, and uses the first entry for a combination" do
    extra = { period: "Summer", hotel: "UnknownHotel", room: "SingletonRoom", rate: -1 }
    duplicate = rate_entries.first.merge(rate: "abc")

    with_fake_rate_api_server(status: 200, body: { rates: rate_entries + [extra, duplicate] }.to_json) do
      assert_equal ALL.index_with(100), RateApiClient.get_rates(ALL)
    end
  end

  test "rejects the whole response when any rate is negative, a decimal, empty, not a number or null" do
    [-1, "-5", 12.5, "12.5", 12000.0, "", "abc", " 100", "100\n", nil, true, [], {}].each do |invalid|
      entries = rate_entries
      entries[3] = entries[3].merge(rate: invalid)

      with_fake_rate_api_server(status: 200, body: { rates: entries }.to_json) do
        error = assert_raises(RateApiClient::ResponseError, "rate #{invalid.inspect}") { RateApiClient.get_rates(ALL) }
        assert_match(/\Ainvalid rate .+ \(HTTP 200\)/, error.message)
      end
    end
  end

  test "rejects entries without a rate, as the model sometimes sends them" do
    entries = rate_entries.map { |entry| entry.except(:rate) }

    with_fake_rate_api_server(status: 200, body: { rates: entries }.to_json) do
      error = assert_raises(RateApiClient::ResponseError) { RateApiClient.get_rates(ALL) }
      assert_match %r{\Ainvalid rate nil for Summer/FloatingPointResort/SingletonRoom \(HTTP 200\)}, error.message
    end
  end

  test "rejects the response when a requested combination is missing" do
    with_fake_rate_api_server(status: 200, body: { rates: rate_entries.drop(1) }.to_json) do
      error = assert_raises(RateApiClient::ResponseError) { RateApiClient.get_rates(ALL) }
      assert_match %r{\Ano rate for 1 of 36 combinations, e.g. Summer/FloatingPointResort/SingletonRoom}, error.message
    end
  end

  test "rejects responses that aren't 2xx JSON with a rates array, and says why with the status and body" do
    {
      { status: 500, body: '{"error":"An unexpected internal error occurred"}' } =>
        /\Aunexpected status \(HTTP 500\): \{"error":"An unexpected internal error occurred"\}\z/,
      { status: 302, body: "" } => /\Aunexpected status \(HTTP 302\)/,
      { status: 200, body: "<html><body>Bad gateway</body></html>", content_type: "text/html" } =>
        /\Abody is not JSON \(HTTP 200\): <html><body>Bad gateway/,
      { status: 200, body: "" } => /\Abody is not JSON \(HTTP 200\)/,
      { status: 204, body: "" } => /\Abody is not JSON \(HTTP 204\)/,
      { status: 200, body: '{"message":"Failed to process rates due to an intermittent issue.","status":"error"}' } =>
        /\Ano rates array \(HTTP 200\): \{"message":"Failed to process rates/,
      { status: 200, body: '{"rates":null}' } => /\Ano rates array \(HTTP 200\)/,
      { status: 200, body: "[]" } => /\Ano rates array \(HTTP 200\)/
    }.each do |response, message|
      with_fake_rate_api_server(response) do
        error = assert_raises(RateApiClient::ResponseError, response.inspect) { RateApiClient.get_rates(ALL) }
        assert_match message, error.message
      end
    end
  end

  test "keeps only the first part of a long body in the error message" do
    with_fake_rate_api_server(status: 500, body: "x" * 5_000, content_type: "text/plain") do
      error = assert_raises(RateApiClient::ResponseError) { RateApiClient.get_rates(ALL) }
      assert_equal "unexpected status (HTTP 500): #{'x' * (RateApiClient::BODY_PREVIEW_LENGTH - 3)}...", error.message
    end
  end

  test "raises TooManyRequestsError on a 429, when the token's daily quota is used up" do
    with_fake_rate_api_server(status: 429, body: '{"error":"Too many requests"}') do
      error = assert_raises(RateApiClient::TooManyRequestsError) { RateApiClient.get_rates(ALL) }
      assert_match(/\Atoo many requests \(HTTP 429\)/, error.message)
    end
  end

  test "gives up when the model doesn't answer within the read timeout" do
    read_timeout = RateApiClient.default_options.fetch(:read_timeout)

    with_fake_rate_api_server(status: 200, body: rates_body, delay: read_timeout + 2) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(RateApiClient::TimeoutError) { RateApiClient.get_rates(ALL) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_in_delta read_timeout, elapsed, 0.5
      assert_match(/Net::ReadTimeout/, error.message)
    end
  end

  test "raises ConnectionError when the connection is refused" do
    closed_port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    previous_base_uri = RateApiClient.base_uri
    RateApiClient.base_uri "http://127.0.0.1:#{closed_port}"

    error = assert_raises(RateApiClient::ConnectionError) { RateApiClient.get_rates(ALL) }
    assert_match(/Errno::ECONNREFUSED/, error.message)
  ensure
    RateApiClient.default_options[:base_uri] = previous_base_uri if previous_base_uri
  end

  test "raises ConnectionError when the connection closes without an answer" do
    with_fake_rate_api_server(drop: true) do
      error = assert_raises(RateApiClient::ConnectionError) { RateApiClient.get_rates(ALL) }
      assert_match(/EOFError/, error.message)
    end
  end

  test "raises ConnectionError when the model's host name can't be resolved" do
    RateApiClient.stub(:post, ->(*, **) { raise SocketError, "getaddrinfo: Name does not resolve" }) do
      error = assert_raises(RateApiClient::ConnectionError) { RateApiClient.get_rates(ALL) }
      assert_match(/SocketError/, error.message)
    end
  end

  private

  # A rate for every combination, in the shape of the model's response entries
  def rate_entries(rate: 100)
    ALL.map { |attribute| attribute.merge(rate:) }
  end

  def rates_body(rate: 100)
    { rates: rate_entries(rate:) }.to_json
  end
end
