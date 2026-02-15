class AdminController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  before_action :verify_secret_token

  def full_reset
    # Truncate all tables except schema_migrations
    tables = ActiveRecord::Base.connection.tables - ['schema_migrations']

    tables.each do |table|
      ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{table} CASCADE")
    end

    # Clear Solid Queue jobs
    SolidQueue::Job.delete_all

    # Re-run seeds
    Rails.application.load_seed

    render plain: "✓ Database completely reset and seeded\n\nUsers:\n- carmin@las-noches.com (super_admin)\n- demo@example.com (user)\n\nPassword: Tres-Leches16!\n\nSuppliers:\n- US Foods\n- Chef's Warehouse\n- What Chefs Want\n- Premiere Produce One"
  rescue StandardError => e
    render plain: "Error: #{e.message}", status: :internal_server_error
  end

  private

  def verify_secret_token
    secret = ENV['ADMIN_SECRET_TOKEN']
    return unless secret.blank? || params[:token] != secret

    render plain: 'Unauthorized', status: :unauthorized
  end
end
