require "test_helper"

# RateCache with real threads. Every wait has a time limit, so a broken implementation fails these
# tests instead of hanging them.
class RateCacheThreadsTest < ActiveSupport::TestCase
  RATES = PricingInventory::ALL.index_with(100).freeze

  test "makes one model call when many requests come at the same time" do
    client = FakeRateApiClient.new do
      sleep 0.2 # long enough for all the requests to arrive during the call
      RATES
    end
    cache = RateCache.new(client:, logger: Logger.new(IO::NULL))

    results = values_of(Array.new(50) { Thread.new { cache.rates } })

    assert_equal 1, client.calls
    assert(results.all? { |rates| rates == RATES })
  end

  test "requests that waited for a failing call don't call the model again" do
    client = FakeRateApiClient.new do
      sleep 0.1
      raise RateApiClient::ResponseError, "unexpected status (HTTP 500)"
    end
    cache = RateCache.new(client:, logger: Logger.new(IO::NULL))

    results = values_of(Array.new(20) { Thread.new { cache.rates rescue $! } })

    assert_equal 2, client.calls, "the call and its retry, then the cooldown"
    assert results.all?(RateCache::Unavailable)
  end

  test "requests don't wait while one of them refreshes the snapshot early" do
    clock = FakeClock.new
    release = Queue.new
    client = FakeRateApiClient.new do |call|
      release.pop if call == 2 # the refresh stays in its model call until the test releases it
      PricingInventory::ALL.index_with(call)
    end
    cache = RateCache.new(client:, clock:, logger: Logger.new(IO::NULL))
    old_rates = cache.rates
    clock.advance(280)

    refresher = Thread.new { cache.rates }
    wait_until(timeout: 2) { client.calls == 2 }

    started = monotonic_now
    results = values_of(Array.new(20) { Thread.new { cache.rates } }, timeout: 1)
    waited = monotonic_now - started

    assert(results.all? { |rates| rates == old_rates }, "the others get the current snapshot")
    assert_operator waited, :<, 0.5

    release << :done
    assert_equal PricingInventory::ALL.index_with(2), values_of([refresher]).first
  ensure
    release&.push(:done)
  end

  private

  # Waits for the threads and returns their values. Fails if one is still running after `timeout` s.
  def values_of(threads, timeout: 5)
    deadline = monotonic_now + timeout
    threads.map do |thread|
      thread.join([deadline - monotonic_now, 0].max) or flunk("a request was still waiting after #{timeout} s")
      thread.value
    end
  end

  def wait_until(timeout:)
    deadline = monotonic_now + timeout
    until yield
      flunk("still waiting after #{timeout} s") if monotonic_now > deadline
      sleep 0.001
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
