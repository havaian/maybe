# Health check controller for monitoring deployment status
class HealthController < ApplicationController
  # Skip any authentication or CSRF protection for health checks
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!, if: :devise_controller?
  
  def index
    health_status = {
      status: 'ok',
      timestamp: Time.current.iso8601,
      version: ENV['BUILD_COMMIT_SHA'] || 'unknown',
      environment: Rails.env
    }
    
    # Check database connectivity
    begin
      ActiveRecord::Base.connection.execute('SELECT 1')
      health_status[:database] = 'connected'
    rescue => e
      health_status[:database] = 'error'
      health_status[:database_error] = e.message
      health_status[:status] = 'error'
    end
    
    # Check Redis connectivity
    begin
      if defined?(Redis)
        redis = Redis.new(url: ENV['REDIS_URL'])
        redis.ping
        health_status[:redis] = 'connected'
      else
        health_status[:redis] = 'not_configured'
      end
    rescue => e
      health_status[:redis] = 'error'
      health_status[:redis_error] = e.message
      health_status[:status] = 'error'
    end
    
    # Check if we're in self-hosted mode
    health_status[:self_hosted] = Rails.application.config.app_mode.self_hosted?
    
    # Return appropriate HTTP status
    status_code = health_status[:status] == 'ok' ? 200 : 503
    
    render json: health_status, status: status_code
  end
  
  # Simple ping endpoint for basic connectivity tests
  def ping
    render json: { message: 'pong', timestamp: Time.current.iso8601 }
  end
end