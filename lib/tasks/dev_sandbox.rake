# Dev-only sandbox companies for repeatedly testing onboarding.
#
#   bin/rails "sandbox:spawn[Test Kitchen]"        # clone the busiest location's lists
#   bin/rails sandbox:list
#   bin/rails "sandbox:teardown[123]"              # by org id
#   bin/rails sandbox:teardown_all
#
namespace :sandbox do
  desc 'Spawn a bare sandbox company (live-flow test: connect real credentials in the UI)'
  task :spawn, [:name] => :environment do |_t, args|
    name = args[:name].presence || "Kitchen #{Time.current.strftime('%H%M')}"
    summary = Dev::CompanySandbox.spawn(name: name)
    puts "Spawned #{summary[:org_name]} (org #{summary[:org_id]}) — #{summary[:mode]}"
    puts "  login:    #{summary[:login]}"
    puts "  password: #{summary[:password]}"
    puts "  Sign in, connect your real supplier credentials, and live the chef-owner experience."
    puts "  (Solid Queue worker must be running for scraping jobs: bin/jobs)"
    puts "  Afterwards: bin/rails \"sandbox:timeline[#{summary[:org_id]}]\" for the patience report."
  end

  desc 'Patience report: elapsed time for every onboarding step of a sandbox org'
  task :timeline, [:org_id] => :environment do |_t, args|
    org = Organization.find(args[:org_id])
    puts "Timeline for #{org.name}:"
    Dev::CompanySandbox.timeline(org).each { |line| puts "  #{line}" }
  end

  desc 'List sandbox companies'
  task list: :environment do
    Dev::CompanySandbox.list.each do |org|
      puts "#{org.id}: #{org.name} (created #{org.created_at.strftime('%m/%d %H:%M')})"
    end
  end

  desc 'Tear down one sandbox company by org id'
  task :teardown, [:org_id] => :environment do |_t, args|
    org = Organization.find(args[:org_id])
    Dev::CompanySandbox.teardown(org)
    puts "Destroyed #{org.name}"
  end

  desc 'Tear down ALL sandbox companies'
  task teardown_all: :environment do
    count = Dev::CompanySandbox.teardown_all
    puts "Destroyed #{count} sandbox #{'company'.pluralize(count)}"
  end
end
