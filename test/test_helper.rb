ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require_relative "support/fake_clock"
require_relative "support/fake_rate_api_client"
require_relative "support/fake_rate_api_server"

# Every call to the real rate-api counts against the token's daily quota, so no test may make one.
# Tests that need HTTP use FakeRateApiServer. A call that isn't stubbed ends up on this port, where
# nothing listens, and fails right away.
RateApiClient.base_uri "http://127.0.0.1:1"

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...

  # Runs the block with RateApiClient pointed at a FakeRateApiServer that gives these responses.
  def with_fake_rate_api_server(*responses)
    server = FakeRateApiServer.new(*responses)
    previous_base_uri = RateApiClient.base_uri
    RateApiClient.base_uri server.url
    yield server
  ensure
    RateApiClient.default_options[:base_uri] = previous_base_uri if previous_base_uri
    server&.close
  end
end
