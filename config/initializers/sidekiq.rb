Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

  # Load scheduled jobs from sidekiq.yml
  config.on(:startup) do
    schedule_file = Rails.root.join("config", "sidekiq.yml")
    if File.exist?(schedule_file)
      yaml_config = YAML.load_file(schedule_file, permitted_classes: [Symbol])
      # Handle both :scheduler: :schedule: and :schedule: formats
      schedule = yaml_config.dig(:scheduler, :schedule) || yaml_config[:schedule]
      if schedule
        Sidekiq.schedule = schedule
        SidekiqScheduler::Scheduler.instance.reload_schedule!
        Rails.logger.info "[Sidekiq] Loaded #{schedule.keys.count} scheduled jobs: #{schedule.keys.join(', ')}"
      end
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
