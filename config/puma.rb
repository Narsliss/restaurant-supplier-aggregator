max_threads_count = ENV.fetch('RAILS_MAX_THREADS') { 5 }
min_threads_count = ENV.fetch('RAILS_MIN_THREADS') { max_threads_count }
threads min_threads_count, max_threads_count

# Fork Puma workers in production for better concurrency.
# WEB_CONCURRENCY=2 → 2 workers × 5 threads = 10 concurrent requests.
workers ENV.fetch('WEB_CONCURRENCY', 0)

# Pre-load app for faster worker boot with copy-on-write memory savings.
preload_app! if ENV.fetch('WEB_CONCURRENCY', '0').to_i > 0

worker_timeout 3600 if ENV.fetch('RAILS_ENV', 'development') == 'development'

port ENV.fetch('PORT') { 3000 }

environment ENV.fetch('RAILS_ENV') { 'development' }

pidfile ENV.fetch('PIDFILE') { 'tmp/pids/server.pid' }

plugin :tmp_restart

# In development, run Solid Queue inside Puma for convenience (single process).
# In production, a dedicated worker service handles all background jobs,
# keeping the web process lean and responsive.
plugin :solid_queue unless ENV['RAILS_ENV'] == 'production'
