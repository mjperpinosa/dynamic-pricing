class Api::V1::PricingController < ApplicationController
  # the valid periods, hotels, and rooms are now defined in PricingInventory
  VALID_PERIODS = PricingInventory::PERIODS
  VALID_HOTELS = PricingInventory::HOTELS
  VALID_ROOMS = PricingInventory::ROOMS

  before_action :validate_params

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]

    service = Api::V1::PricingService.new(period:, hotel:, room:)
    service.run
    if service.valid?
      render json: { rate: service.result }
    else
      # if the model is not providing a valid rate, or if the Rate API returned any error, tell the client to retry
      response.set_header("Retry-After", service.retry_after.to_s)
      #render json: { error: service.errors.join(', ') }, status: :bad_request
      render json: {error: service.errors.join(',')}, status: :service_unavailable
    end
  end

  private

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
    end

    # Validate parameter values
    unless VALID_PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}" }, status: :bad_request
    end

    unless VALID_HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}" }, status: :bad_request
    end

    unless VALID_ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}" }, status: :bad_request
    end
  end
end
