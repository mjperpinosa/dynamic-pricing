# Limiting/throttling for the model's daily quota

class TokenBucket
  def initialize(capacity:, refill_interval:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @capacity = capacity.to_f
    @refill_interval = refill_interval.to_f
    @clock = clock
    @tokens = @capacity
    @refilled_at = clock.call
    @mutex = Mutex.new
  end

  # Takes one token. when the bucket is empty, returns false
  def take
    @mutex.synchronize do
      refill
      if @tokens >= 1
        @tokens -= 1
        true
      else
        false
      end
    end
  end

  # Whole tokens left in the bucket
  def tokens
    @mutex.synchronize do
      refill
      @tokens.floor
    end
  end

  # Seconds until the next whole token comes in (0 when one is available now).
  def seconds_until_next_token
    @mutex.synchronize do
      refill
      @tokens >= 1 ? 0.0 : (1 - @tokens) * @refill_interval
    end
  end

  private

  # Adds the tokens earned since the last refill. Callers must hold @mutex.
  def refill
    now = @clock.call
    @tokens = [@capacity, @tokens + (now - @refilled_at) / @refill_interval].min
    @refilled_at = now
  end
end
