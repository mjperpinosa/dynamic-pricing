require "test_helper"

# GET /api/v1/pricing through the real controller, service, cache and client. Only rate-api is
# replaced, by FakeRateApiServer, so these tests don't use the model's daily quota.
class PricingEndToEndTest < ActionDispatch::IntegrationTest
  PARAMS = { period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom" }.freeze

  setup do
    @cache = RateCache.new(logger: Logger.new(IO::NULL))
  end

  test "returns the model's rate as an integer, and serves the next requests from the cache" do
    entries = PricingInventory::ALL.map { |attribute| attribute.merge(rate: attribute == PARAMS ? "15000" : "100") }

    with_fake_rate_api_server(status: 200, body: { rates: entries }.to_json) do |server|
      3.times do
        get_pricing

        assert_response :success
        assert_equal({ "rate" => 15000 }, JSON.parse(@response.body))
      end
      assert_equal 1, server.requests.size
    end
  end

  test "returns 503 with Retry-After when the model returns an error, without passing its response on" do
    with_fake_rate_api_server(status: 500, body: '{"error":"An unexpected internal error occurred"}') do |server|
      get_pricing

      assert_unavailable "the pricing model returned an error", retry_after: 5
      assert_not_includes @response.body, "unexpected internal error"
      assert_equal 2, server.requests.size, "the call and its retry"
    end
  end

  test "returns 503 with Retry-After when the model doesn't answer in time" do
    read_timeout = RateApiClient.default_options[:read_timeout]
    RateApiClient.read_timeout 0.2 # keeps this test fast; RateApiClientTest checks the real timeout

    with_fake_rate_api_server(status: 200, body: "{}", delay: 1) do
      get_pricing

      assert_unavailable "the pricing model did not respond in time", retry_after: 5
    end
  ensure
    RateApiClient.default_options[:read_timeout] = read_timeout
  end

  test "returns 503 with Retry-After when the connection to the model breaks" do
    with_fake_rate_api_server(drop: true) do
      get_pricing

      assert_unavailable "the pricing model could not be reached", retry_after: 5
    end
  end

  test "returns 503 with Retry-After when the model's daily quota is used up" do
    with_fake_rate_api_server(status: 429, body: '{"error":"Too many requests"}') do |server|
      get_pricing

      assert_unavailable "the pricing model's daily quota is used up", retry_after: 60
      assert_equal 1, server.requests.size, "no retry after a 429"
    end
  end

  test "returns 503 with Retry-After when our budget for model calls is used up" do
    budget = TokenBucket.new(capacity: 1, refill_interval: 144, clock: FakeClock.new)
    @cache = RateCache.new(logger: Logger.new(IO::NULL), budget:)

    with_fake_rate_api_server(status: 500, body: '{"error":"An unexpected internal error occurred"}') do |server|
      get_pricing

      assert_unavailable "requests to the pricing model are being throttled to stay within its daily quota",
                         retry_after: 144
      assert_equal 1, server.requests.size, "no token left for the retry"
    end
  end

  private

  def get_pricing
    RateCache.stub(:instance, @cache) do
      get api_v1_pricing_url, params: PARAMS
    end
  end

  def assert_unavailable(reason, retry_after:)
    assert_response :service_unavailable
    assert_equal "application/json", @response.media_type
    assert_equal retry_after.to_s, @response.headers["Retry-After"]
    assert_equal "Pricing is temporarily unavailable: #{reason}. Please retry in #{retry_after} seconds.",
                 JSON.parse(@response.body)["error"]
  end
end
