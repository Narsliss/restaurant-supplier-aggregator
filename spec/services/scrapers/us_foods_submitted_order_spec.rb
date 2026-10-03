require 'rails_helper'

# Order #332 was submitted as 1a33fcdd-… but US Foods later re-filed it as
# ff9943c0-… (tandem 648653), so a later check could no longer find it by the
# id we saved. Fixture: Alfio's live recentorders, Oct 3 2026, trimmed.
RSpec.describe Scrapers::UsFoodsScraper, '#fetch_submitted_order' do
  let(:credential) { create(:supplier_credential) }
  let(:scraper) { described_class.new(credential) }
  let(:live) { JSON.parse(file_fixture('usf_recent_orders_2026_10_03.json').read) }
  let(:refiled) { live.find { |o| o['tandemOrderNumber'].to_s == '648653' } }
  let(:our_skus) { refiled['orderItems'].map { |li| li['productNumber'].to_s } }
  let(:api) { double('UsFoodsApi', ensure_session!: true, get_recent_orders: live) }

  before { allow(scraper).to receive(:api_client).and_return(api) }

  it 'still finds an order by the id we saved' do
    expect(scraper.fetch_submitted_order(refiled['orderId'])).to eq(refiled)
  end

  it 'finds the re-filed order by delivery date and items when the saved id is gone' do
    found = scraper.fetch_submitted_order('1a33fcdd-83da-4bdb-973d-c4051e7e2e3c',
                                          delivery_date: Date.new(2026, 9, 28), skus: our_skus)
    expect(found['tandemOrderNumber']).to eq(648653).or eq('648653')
  end

  it 'tolerates a chef adding or dropping a few lines on US Foods\' site' do
    found = scraper.fetch_submitted_order('gone', delivery_date: Date.new(2026, 9, 28),
                                                  skus: our_skus.first(9) + %w[999 998])
    expect(found).to eq(refiled)
  end

  it 'does not match an order for another delivery date' do
    expect(scraper.fetch_submitted_order('gone', delivery_date: Date.new(2026, 9, 29), skus: our_skus)).to be_nil
  end

  it 'does not match when too few of our items are on it' do
    expect(scraper.fetch_submitted_order('gone', delivery_date: Date.new(2026, 9, 28),
                                                 skus: our_skus.first(2) + %w[1 2 3 4 5 6])).to be_nil
  end

  it 'never matches an abandoned draft' do
    draft = live.find { |o| o['orderStatus'] == 'DELETED' }
    skus = draft['orderItems'].map { |li| li['productNumber'].to_s }
    shipped = live.find { |o| o['orderStatus'] == 'SHIPPED' }

    found = scraper.fetch_submitted_order('gone', delivery_date: Date.new(2026, 10, 3), skus: skus)
    expect(found).to eq(shipped) # same day and items, but the real order, not the draft
  end
end
