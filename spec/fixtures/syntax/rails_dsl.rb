# frozen_string_literal: true
# min_ruby: 3.1.0

Rails.application.routes.draw do
  namespace :api, defaults: {format: :json} do
    namespace :v1 do
      resources :users do
        collection do
          get "search"
          post "bulk_create"
        end
      end
    end
  end

  root to: "home#index"
end

class ApplicationController < ActionController::Base
  before_action :authenticate_user!, except: %i[index show]

  rescue_from StandardError do |error|
    render json: {error: error.message}, status: :internal_server_error
  end
end
