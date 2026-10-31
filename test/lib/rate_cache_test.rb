require "test_helper"

# RateCache with a fake clock and a fake client: each test moves time by hand and decides what the
# model does on every call.
class RateCacheTest < ActiveSupport::TestCase
  RATES = PricingInventory::ALL.index_with(100).freeze
  NEW_RATES = PricingInventory::ALL.index_with(200).freeze

  setup do
    @clock = FakeClock.new
    @log = StringIO.new
    @logger = Logger.new(@log, formatter: ->(_severity, _time, _program, message) { "#{message}\n" })
  end

  test "asks the model for all the combinations in one call" do
    asked_for = nil
    client = FakeRateApiClient.new do |_call, attributes|
      asked_for = attributes
      RATES
    end

    assert_equal RATES, new_cache(client).rates
    assert_equal 1, client.calls
    assert_equal PricingInventory::ALL, asked_for
  end

  test "keeps the rates in an immutable snapshot" do
    rates = new_cache(FakeRateApiClient.new { RATES.dup }).rates

    assert_predicate rates, :frozen?
  end

  test "counts a snapshot's age from when its model call started" do
    client = FakeRateApiClient.new do |call|
      @clock.advance(2) # each call takes 2 s
      call == 1 ? RATES : NEW_RATES
    end
    cache = new_cache(client)
    cache.rates # started at 1000, done at 1002

    @clock.advance(267)
    assert_equal RATES, cache.rates, "269 s after the call started: served from the snapshot"
    assert_equal 1, client.calls

    @clock.advance(1)
    assert_equal NEW_RATES, cache.rates, "270 s after the call started: refreshed"
    assert_equal 2, client.calls
  end

  test "measures age with the monotonic clock, so changing the system time doesn't affect it" do
    client = FakeRateApiClient.new { RATES }
    cache = RateCache.new(client:, logger: @logger)
    cache.rates

    travel 10.minutes do # moves the wall clock only
      assert_equal RATES, cache.rates
    end
    assert_equal 1, client.calls
  end

  test "never serves a snapshot once it's 5 minutes old" do
    client = FakeRateApiClient.new do |call|
      raise RateApiClient::ResponseError, "unexpected status (HTTP 500)" if call > 1

      @clock.advance(2) # the first call takes 2 s
      RATES
    end
    cache = new_cache(client)
    cache.rates # started at 1000, done at 1002

    @clock.advance(297)
    assert_equal RATES, cache.rates, "299 s old: the refresh fails, and the snapshot is still served"
    assert_equal 3, client.calls

    @clock.advance(1)
    error = assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal :error, error.reason
    assert_equal 3, client.calls, "no call during the cooldown"
  end

  test "doesn't serve the old snapshot when a failing refresh takes it past 5 minutes" do
    client = FakeRateApiClient.new do |call|
      next RATES if call == 1

      @clock.advance(3) # the read timeout
      raise RateApiClient::TimeoutError, "no response in time (Net::ReadTimeout)"
    end
    cache = new_cache(client)
    cache.rates

    @clock.advance(296)
    # 296 s old when the refresh starts, 302 s old when its retry gives up
    error = assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal :timeout, error.reason
    assert_equal 3, client.calls
  end

  test "refreshes early, and serves the old snapshot while the refresh fails" do
    client = FakeRateApiClient.new do |call|
      raise RateApiClient::TimeoutError, "no response in time (Net::ReadTimeout)" if call > 1

      RATES
    end
    cache = new_cache(client)
    cache.rates

    @clock.advance(280)
    assert_equal RATES, cache.rates, "the call and its retry fail: the old snapshot is served"
    assert_equal 3, client.calls

    @clock.advance(4)
    assert_equal RATES, cache.rates, "cooldown: no call, and the old snapshot is served"
    assert_equal 3, client.calls

    @clock.advance(1)
    assert_equal RATES, cache.rates, "cooldown over: the next request tries again"
    assert_equal 5, client.calls
  end

  test "retries a failed call once, right away" do
    client = FakeRateApiClient.new do |call|
      raise RateApiClient::ResponseError, "unexpected status (HTTP 500)" if call == 1

      RATES
    end

    assert_equal RATES, new_cache(client).rates
    assert_equal 2, client.calls
  end

  test "doesn't call the model for 5 seconds after the retry fails too" do
    client = FakeRateApiClient.new { raise RateApiClient::ConnectionError, "connection failed (Errno::ECONNREFUSED)" }
    cache = new_cache(client)

    error = assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal [:unreachable, 5], [error.reason, error.retry_after]
    assert_equal 2, client.calls
    assert_equal [nil, 5.0], log_lines.map { |line| line["cooldown_s"] }, "the second failure starts the cooldown"

    @clock.advance(2.5)
    error = assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal [:unreachable, 3], [error.reason, error.retry_after], "2.5 s left, rounded up"
    assert_equal 2, client.calls

    @clock.advance(2.5)
    assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal 4, client.calls, "cooldown over: the call and its retry"
  end

  test "doesn't retry after a 429, and doesn't call the model for 60 seconds" do
    client = FakeRateApiClient.new { raise RateApiClient::TooManyRequestsError, "too many requests (HTTP 429)" }
    cache = new_cache(client)

    error = assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal [:quota_used_up, 60], [error.reason, error.retry_after]
    assert_equal 1, client.calls

    @clock.advance(59)
    assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal 1, client.calls

    @clock.advance(1)
    assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal 2, client.calls
  end

  test "treats an unexpected exception from the client as a failed call" do
    client = FakeRateApiClient.new { raise NoMethodError, "undefined method 'fetch' for nil" }

    error = assert_raises(RateCache::Unavailable) { new_cache(client).rates }
    assert_equal :error, error.reason
    assert_equal 2, client.calls
  end

  test "doesn't call the model while the budget is empty, until its next token comes in" do
    budget = TokenBucket.new(capacity: 3, refill_interval: 100, clock: @clock)
    client = FakeRateApiClient.new { raise RateApiClient::ResponseError, "unexpected status (HTTP 500)" }
    cache = new_cache(client, budget:)
    assert_raises(RateCache::Unavailable) { cache.rates } # the call and its retry leave 1 token

    @clock.advance(5) # the cooldown is over, and 0.05 of a token came in
    # the call takes the last token, and the retry finds none
    error = assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal 3, client.calls
    assert_equal :throttled, error.reason
    assert_includes 95..96, error.retry_after, "the next token comes in 95 s"

    @clock.advance(94)
    assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal 3, client.calls, "no call before the next token"

    @clock.advance(1.5)
    assert_raises(RateCache::Unavailable) { cache.rates }
    assert_equal 4, client.calls

    exhausted = log_lines.select { |line| line["event"] == "rate_api_budget_exhausted" }
    assert_equal 2, exhausted.size
    assert_equal({ "attempt" => 2, "tokens_left" => 0 }, exhausted.first.slice("attempt", "tokens_left"))
  end

  test "writes one JSON log line per model call" do
    budget = TokenBucket.new(capacity: 10, refill_interval: 1_000, clock: @clock)
    client = FakeRateApiClient.new do |call|
      if call == 1
        @clock.advance(3)
        raise RateApiClient::TimeoutError, "no response in time (Net::ReadTimeout)"
      end

      @clock.advance(0.5)
      RATES
    end
    cache = new_cache(client, budget:)
    cache.rates # call 1 times out, and its retry succeeds
    @clock.advance(279.5)
    cache.rates # call 3 refreshes the snapshot, 280 s after call 2 started

    assert_equal 3, log_lines.size
    timeout, success, refresh = log_lines
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, timeout["time"])
    assert_equal({ "event" => "rate_api_call", "outcome" => "timeout", "attempt" => 1, "duration_ms" => 3000.0,
                   "tokens_left" => 9, "error" => "RateApiClient::TimeoutError: no response in time (Net::ReadTimeout)" },
                 timeout.except("time"))
    assert_equal({ "event" => "rate_api_call", "outcome" => "success", "attempt" => 2, "duration_ms" => 500.0,
                   "tokens_left" => 8 },
                 success.except("time"))
    assert_equal({ "event" => "rate_api_call", "outcome" => "success", "attempt" => 1, "duration_ms" => 500.0,
                   "tokens_left" => 7, "snapshot_age_s" => 280.0 },
                 refresh.except("time"))
  end

  private

  def new_cache(client, budget: nil)
    RateCache.new(client:, clock: @clock, logger: @logger, budget:)
  end

  def log_lines
    @log.string.lines.map { |line| JSON.parse(line) }
  end
end
