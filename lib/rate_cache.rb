# In-memory cache of the rates for all period x hotel x room combinations, with one instance per process 
class RateCache
  MAX_AGE = 300.0        # in seconds (never serve a snapshot older than 5 mins)
  REFRESH_AGE = 270.0    # in seconds. (if >= 4.5 mins, the next request refreshes the snapshot)
  MAX_ATTEMPTS = 2       # attemps to retry a failed call, except after a 429
  FAILURE_COOLDOWN = 5.0 # seconds without calling the model when the retry failed too
  QUOTA_COOLDOWN = 60.0  # seconds without calling the model after a 429

  # Daily budget for model calls (including failed ones)
  BUDGET_BURST = 350
  BUDGET_PER_DAY = 600

  MONOTONIC_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

  Snapshot = Data.define(:rates, :fetched_at)

  # For issues that arise e.g. timeout, unreachable, error, quota_used_up, throttled.
  class Unavailable < StandardError
    attr_reader :reason, :retry_after

    def initialize(reason:, retry_after:)
      @reason = reason
      @retry_after = retry_after
      super("rates unavailable (#{reason}), retry after #{retry_after}s")
    end
  end

  @instance_lock = Mutex.new

  def self.instance
    @instance_lock.synchronize { @instance ||= new }
  end

  # 86,400 seconds/day, refill interval is 2.4 minutes
  def initialize(client: RateApiClient, clock: MONOTONIC_CLOCK, logger: Rails.logger, budget: nil)
    @client = client
    @clock = clock
    @logger = logger
    @budget = budget || TokenBucket.new(capacity: BUDGET_BURST, refill_interval: 86_400.0 / BUDGET_PER_DAY, clock:)
    @refresh_lock = Mutex.new
    @snapshot = nil
    @cooldown_until = nil
    @cooldown_reason = nil
  end

  # Returns rates for all combinations from a snapshot
  # If the snapshot is too old and the issues arose while callign the model, raise Unavailable
  def rates
    snapshot = @snapshot
    return snapshot.rates unless needs_refresh?(snapshot)
    return early_refresh(snapshot) if fresh?(snapshot)

    # Nothing to serve: wait for the refresh in progress, if any, then call the model only if still needed.
    @refresh_lock.synchronize { refresh_if_needed }.rates
  end

  private

  # Between REFRESH_AGE and MAX_AGE the current snapshot can still be served, so one request
  # refreshes it and the others get the current snapshot right away instead of waiting
  def early_refresh(snapshot)
    return snapshot.rates unless @refresh_lock.try_lock

    begin
      refresh_if_needed.rates
    rescue Unavailable
      raise unless fresh?(snapshot) # it can reach MAX_AGE during a slow call 
      snapshot.rates
    ensure
      @refresh_lock.unlock
    end
  end

  # Callers must hold @refresh_lock. Checks the snapshot again first, another request may have refreshed it while this one was waiting
  def refresh_if_needed
    return @snapshot unless needs_refresh?(@snapshot)

    check_cooldown!
    @snapshot = fetch_snapshot
  end

  # Returns a new snapshot, or starts a cooldown and raises Unavailable.
  def fetch_snapshot
    snapshot_age = age(@snapshot)
    1.upto(MAX_ATTEMPTS) do |attempt|
      take_budget!(attempt)
      started_at = now
      rates, error = call_model
      if rates
        log_call(attempt:, started_at:, snapshot_age:, outcome: :success)
        return Snapshot.new(rates: rates.freeze, fetched_at: started_at)
      end

      reason = failure_reason(error)
      if reason == :quota_used_up || attempt == MAX_ATTEMPTS
        cooldown = reason == :quota_used_up ? QUOTA_COOLDOWN : FAILURE_COOLDOWN
        log_call(attempt:, started_at:, snapshot_age:, outcome: reason, error:, cooldown:)
        start_cooldown!(reason, cooldown)
      end
      log_call(attempt:, started_at:, snapshot_age:, outcome: reason, error:) # retrying right away
    end
  end

  # Any exception counts as a failed call, so even an unexpected one goes through the cooldown.
  def call_model
    [@client.get_rates(PricingInventory::ALL), nil]
  rescue StandardError => e
    [nil, e]
  end

  def failure_reason(error)
    case error
    when RateApiClient::TimeoutError then :timeout
    when RateApiClient::ConnectionError then :unreachable
    when RateApiClient::TooManyRequestsError then :quota_used_up
    else :error
    end
  end

  # Every call takes a token. With none left, don't call the model until the next one comes in.
  def take_budget!(attempt)
    return if @budget.take

    wait = @budget.seconds_until_next_token
    log(:warn, event: "rate_api_budget_exhausted", attempt:, tokens_left: @budget.tokens, cooldown_s: wait.round(1))
    start_cooldown!(:throttled, wait)
  end

  # A circuit breaker without a half-open state: no model calls until the cooldown is over.
  def start_cooldown!(reason, seconds)
    @cooldown_until = now + seconds
    @cooldown_reason = reason
    raise Unavailable.new(reason:, retry_after: whole_seconds(seconds))
  end

  def check_cooldown!
    return if @cooldown_until.nil? || now >= @cooldown_until

    raise Unavailable.new(reason: @cooldown_reason, retry_after: whole_seconds(@cooldown_until - now))
  end

  # Retry-After takes whole seconds: round up so clients don't come back too early.
  def whole_seconds(seconds)
    [seconds.ceil, 1].max
  end

  def log_call(attempt:, started_at:, snapshot_age:, outcome:, error: nil, cooldown: nil)
    log(outcome == :success ? :info : :warn,
        event: "rate_api_call",
        outcome:,
        attempt:,
        duration_ms: ((now - started_at) * 1000).round(1),
        tokens_left: @budget.tokens,
        snapshot_age_s: snapshot_age&.round(1),
        error: error && "#{error.class}: #{error.message}",
        cooldown_s: cooldown)
  end

  def log(level, **fields)
    @logger.public_send(level, { time: Time.now.utc.iso8601(3), **fields }.compact.to_json)
  end

  def needs_refresh?(snapshot)
    snapshot.nil? || age(snapshot) >= REFRESH_AGE
  end

  # Fresh means it can be served: younger than MAX_AGE.
  def fresh?(snapshot)
    !snapshot.nil? && age(snapshot) < MAX_AGE
  end

  def age(snapshot)
    snapshot && now - snapshot.fetched_at
  end

  def now
    @clock.call
  end
end
