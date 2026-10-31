require "test_helper"

# Whole days of traffic against RateCache, with a fake clock so that a day takes about a second.
class RateCacheSimulatedDayTest < ActiveSupport::TestCase
  DAY = 86_400
  MODEL_DAILY_QUOTA = 1_000

  test "a day of 12,000 requests with 27% of the model calls failing" do
    day = simulate_day(requests: 12_000, failure_rate: 0.27)

    assert_operator day[:calls], :<=, MODEL_DAILY_QUOTA, day.inspect
    assert_operator day[:oldest_served], :<, 300, day.inspect
    assert_operator day[:served], :>=, 0.99 * 12_000, day.inspect
  end

  test "a day with the model down stays within the budget" do
    day = simulate_day(requests: 12_000, failure_rate: 1.0)

    assert_operator day[:calls], :<=, RateCache::BUDGET_BURST + RateCache::BUDGET_PER_DAY, day.inspect
    assert_operator day[:calls], :<=, MODEL_DAILY_QUOTA, day.inspect
    assert_equal 0, day[:served]
  end

  test "a day of 200,000 requests with the model down stays within the budget" do
    day = simulate_day(requests: 200_000, failure_rate: 1.0)

    assert_operator day[:calls], :<=, RateCache::BUDGET_BURST + RateCache::BUDGET_PER_DAY, day.inspect
    assert_operator day[:calls], :<=, MODEL_DAILY_QUOTA, day.inspect
  end

  private

  # Sends `requests` requests at random times over a day. Each model call fails with probability
  # `failure_rate`, half of the failures as 5 ms errors and half as 3 s timeouts. Returns the model
  # calls made, the requests served and refused, and the age of the oldest rates served, counted
  # from the start of the call that fetched them.
  def simulate_day(requests:, failure_rate:)
    random = Random.new(42)
    clock = FakeClock.new(0.0)
    call_started_at = {}.compare_by_identity
    client = FakeRateApiClient.new do
      started_at = clock.now
      if random.rand < failure_rate
        if random.rand < 0.5
          clock.advance(3)
          raise RateApiClient::TimeoutError, "no response in time (Net::ReadTimeout)"
        end
        clock.advance(0.005)
        raise RateApiClient::ResponseError, "unexpected status (HTTP 500)"
      end
      clock.advance(0.005)
      PricingInventory::ALL.index_with(100).tap { |rates| call_started_at[rates] = started_at }
    end
    cache = RateCache.new(client:, clock:, logger: Logger.new(IO::NULL))

    served = refused = 0
    oldest_served = 0.0
    Array.new(requests) { random.rand * DAY }.sort.each do |time|
      clock.advance(time - clock.now) if time > clock.now
      rates = cache.rates
      served += 1
      oldest_served = [oldest_served, clock.now - call_started_at.fetch(rates)].max
    rescue RateCache::Unavailable
      refused += 1
    end
    { calls: client.calls, served:, refused:, oldest_served: }
  end
end
