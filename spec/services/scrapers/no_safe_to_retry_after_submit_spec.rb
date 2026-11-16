require "rails_helper"

# Risk #4 (Oct 20 2026): after the live submit goes out, the chef is never
# told it is "safe to try again" — a retry could place a second order while
# the supplier is still taking the first. Refusals before the submit say
# "Try again." and are fine; this phrase was only ever used after it.
RSpec.describe "Scraper wording after a live submit" do
  it "never tells the chef it is safe to try again" do
    offenders = Dir[Rails.root.join("app/services/scrapers/**/*.rb")].select do |path|
      File.read(path).match?(/safe to (try again|retry)/i)
    end

    expect(offenders.map { |p| Pathname(p).relative_path_from(Rails.root).to_s }).to be_empty
  end
end
