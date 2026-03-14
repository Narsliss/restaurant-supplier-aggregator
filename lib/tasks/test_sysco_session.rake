# frozen_string_literal: true

namespace :sysco do
  desc 'Test Sysco search with proper auth verification'
  task test_memory: :environment do
    credential = SupplierCredential.joins(:supplier)
                                   .where('suppliers.name ILIKE ?', '%sysco%')
                                   .first

    abort 'No Sysco credential found' unless credential

    # Enable Rails logger to STDOUT so we can see scraper logs
    Rails.logger = Logger.new($stdout)
    Rails.logger.level = :info

    scraper = Scrapers::SyscoScraper.new(credential)

    scraper.send(:with_browser) do
      b = scraper.send(:browser)

      puts "\n=== Calling ensure_logged_in ==="
      scraper.send(:ensure_logged_in)

      url = b.current_url rescue ''
      puts "\nAfter ensure_logged_in:"
      puts "  URL: #{url}"
      puts "  logged_in?: #{scraper.send(:logged_in?)}"

      # Check role
      role = b.evaluate(<<~JS) rescue 'error'
        (function() {
          var c = document.cookie;
          var m = c.match(/MSS_STATEFUL=([^;]+)/);
          if (!m) return 'no MSS_STATEFUL in document.cookie';
          try {
            var decoded = decodeURIComponent(m[1]);
            var obj = JSON.parse(decoded);
            var parts = obj.token.split('.');
            var payload = JSON.parse(atob(parts[1]));
            return 'role=' + payload.role;
          } catch(e) { return 'parse error'; }
        })()
      JS
      puts "  Role: #{role}"

      if scraper.send(:logged_in?)
        puts "\n✅ Actually authenticated! Testing search..."

        chrome_pid = b.process.pid rescue nil
        def memory_usage(pid)
          return '?' unless pid
          rss = `ps -o rss= -p #{pid} 2>/dev/null`.strip.to_i / 1024
          "#{rss}MB"
        end

        terms = %w[chicken beef pork seafood produce dairy cheese bread flour sugar
                   oil vinegar sauce pasta rice beans corn tomato potato onion
                   lettuce pepper mushroom garlic herb spice salt cream butter
                   milk eggs bacon sausage ham turkey lamb]

        terms.each_with_index do |term, idx|
          scraper.send(:perform_spa_search, term)
          sleep 2

          url = b.current_url rescue ''
          if url.include?('auth/')
            puts "❌ Lost auth at term #{idx + 1} '#{term}'"
            break
          end

          count = b.evaluate("document.querySelectorAll('[class*=\"product-card\"]').length") rescue 0
          mem = memory_usage(chrome_pid)
          puts "[#{idx + 1}/#{terms.size}] '#{term}': #{count} products, memory: #{mem}"
        end
      else
        puts "\n❌ Not actually authenticated after ensure_logged_in"
      end
    end

    puts "\n=== Done ==="
  end
end
