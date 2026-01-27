Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  
  # Load scheduled jobs
  config.on(:startup) do
    schedule_file = Rails.root.join("config", "sidekiq.yml")
    if File.exist?(schedule_file)
      schedule = YAML.load_file(schedule_file)[:schedule]
      if schedule
        Sidekiq.schedule = schedule
        SidekiqScheduler::Scheduler.instance.reload_schedule!
      end
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
