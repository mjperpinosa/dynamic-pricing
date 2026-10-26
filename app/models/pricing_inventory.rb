# the periods, hotels, and rooms that the pricing API supports
# this is used by the PricingController to validate the request params 
# and will be used by caching logic to get the rates of all combination in one call
module PricingInventory
    PERIODS = %w[Summer Autumn Winter Spring].freeze
    HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
    ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

    # generate all combinations of valid period x hotel x room
    ALL = PERIODS.product(HOTELS, ROOMS).map { |period, hotel, room| {
            period: period,
            hotel: hotel,
            room: room
        }.freeze
    }.freeze
end