require "test_helper"

class TokenBucketTest < ActiveSupport::TestCase
  setup do
    @clock = FakeClock.new
  end

  test "starts full and gives no token once it's empty" do
    bucket = TokenBucket.new(capacity: 3, refill_interval: 60, clock: @clock)

    assert_equal [true, true, true, false], Array.new(4) { bucket.take }
    assert_equal 0, bucket.tokens
  end

  test "earns one token per refill interval, never more than its capacity" do
    bucket = TokenBucket.new(capacity: 2, refill_interval: 60, clock: @clock)
    2.times { bucket.take }

    @clock.advance(30)
    assert_not bucket.take, "half a token isn't enough"
    @clock.advance(30)
    assert bucket.take

    @clock.advance(1_000_000)
    assert_equal 2, bucket.tokens
  end

  test "tells how long until the next token comes in" do
    bucket = TokenBucket.new(capacity: 1, refill_interval: 144, clock: @clock)
    assert_equal 0, bucket.seconds_until_next_token

    bucket.take
    assert_in_delta 144, bucket.seconds_until_next_token, 0.001
    @clock.advance(44)
    assert_in_delta 100, bucket.seconds_until_next_token, 0.001
  end

  test "gives at most its capacity plus what it earns, however often it's asked" do
    bucket = TokenBucket.new(capacity: 10, refill_interval: 60, clock: @clock)

    taken = 0
    3_600.times do # one take a second for an hour
      taken += 1 if bucket.take
      @clock.advance(1)
    end

    assert_equal 10 + 59, taken # 59 tokens earned in the 3,599 s between the first take and the last
  end
end
