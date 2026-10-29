module Api::V1
  class PricingService < BaseService
    # What our users are told when no rate can be served. The model's own response only goes to the logs.
    UNAVAILABLE_REASONS = {
      timeout: "the pricing model did not respond in time",
      unreachable: "the pricing model could not be reached",
      error: "the pricing model returned an error",
      quota_used_up: "the pricing model's daily quota is used up",
      throttled: "requests to the pricing model are being throttled to stay within its daily quota"
    }.freeze

    attr_reader :retry_after

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      @result = RateCache.instance.rates.fetch({ period: @period, hotel: @hotel, room: @room })
    rescue RateCache::Unavailable => e
      @retry_after = e.retry_after
      errors << "Pricing is temporarily unavailable: #{UNAVAILABLE_REASONS.fetch(e.reason)}. " \
                "Please retry in #{e.retry_after} #{'second'.pluralize(e.retry_after)}."
    end
  end
end
