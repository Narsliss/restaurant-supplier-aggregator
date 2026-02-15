namespace :admin do
  desc 'Clear all pending jobs from the queue'
  task clear_jobs: :environment do
    puts 'Clearing pending jobs...'

    # Clear Solid Queue jobs
    cleared = SolidQueue::Job.where(finished_at: nil).destroy_all
    puts "Cleared #{cleared.count} pending jobs"

    # Also clear any pending 2FA requests
    tfa_cleared = Supplier2faRequest.where(status: %w[pending submitted]).destroy_all
    puts "Cleared #{tfa_cleared.count} pending 2FA requests"

    puts 'Done!'
  end
end
