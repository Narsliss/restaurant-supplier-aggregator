namespace :teaser_matches do
  desc "Enqueue TeaserCatalogSearchJob for every existing matched/master AggregatedList"
  task backfill: :environment do
    scope = AggregatedList.matched_lists
    total = scope.count
    puts "Enqueuing TeaserCatalogSearchJob for #{total} aggregated lists on :low queue..."

    enqueued = 0
    scope.find_each do |al|
      TeaserCatalogSearchJob.perform_later(al.id)
      enqueued += 1
      puts "  [#{enqueued}/#{total}] enqueued list=#{al.id} (#{al.name})" if (enqueued % 25).zero?
    end

    puts "Done. #{enqueued} jobs enqueued on :low queue."
    puts "Solid Queue config: 1 worker thread on :low — backfill will trickle in serially."
  end

  desc "Run TeaserCatalogSearchService inline for one list (debug)"
  task :run, [:list_id] => :environment do |_t, args|
    list_id = args[:list_id]&.to_i
    abort "usage: rake teaser_matches:run[<aggregated_list_id>]" if list_id.nil? || list_id.zero?

    al = AggregatedList.find(list_id)
    puts "Running TeaserCatalogSearchService inline for list=#{al.id} (#{al.name})..."
    result = TeaserCatalogSearchService.new(al).call
    puts "Result: #{result.inspect}"
    puts "Teaser rows persisted: #{TeaserMatch.where(aggregated_list_id: al.id).count}"
  end
end
