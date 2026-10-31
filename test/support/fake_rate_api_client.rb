# Mock for RateApiClient used in RateCache tests
class FakeRateApiClient
  def initialize(&behavior)
    @behavior = behavior
    @calls = 0
    @mutex = Mutex.new
  end

  def calls
    @mutex.synchronize { @calls }
  end

  def get_rates(attributes)
    call = @mutex.synchronize { @calls += 1 }
    @behavior.call(call, attributes)
  end
end
