# A clock that only moves when a test moves it. RateCache and TokenBucket take it in place of the
# monotonic clock.
class FakeClock
  attr_reader :now

  def initialize(now = 1_000.0)
    @now = now
  end

  def call
    @now
  end

  def advance(seconds)
    @now += seconds
  end
end
