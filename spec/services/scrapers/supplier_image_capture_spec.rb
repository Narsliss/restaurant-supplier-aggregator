# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (PRD: Product Image Thumbnails): each supplier parser must surface an
# `image_url` from the API response so the import sink can persist it. These
# exercise the pure mapping methods directly.
RSpec.describe 'supplier image-url capture' do
  describe Scrapers::UsFoodsScraper, '#usf_image_url' do
    subject(:scraper) { described_class.allocate }

    let(:summary) do
      {
        'productAssets' => {
          'productImages' => {
            'C1CC' => { 'renditions' => { 'Small' => 'https://assets.usfoods.com/s.jpg',
                                          'Medium' => 'https://assets.usfoods.com/m.jpg' } }
          }
        }
      }
    end

    it 'prefers the Small rendition' do
      expect(scraper.send(:usf_image_url, summary)).to eq('https://assets.usfoods.com/s.jpg')
    end

    it 'returns nil when no product assets exist' do
      expect(scraper.send(:usf_image_url, { 'productNumber' => 1 })).to be_nil
      expect(scraper.send(:usf_image_url, {})).to be_nil
    end
  end

  describe Scrapers::SyscoScraper, '#parse_search_result' do
    subject(:scraper) { described_class.allocate }

    it 'captures the first non-blank productInfo image' do
      result = {
        'productId' => '123',
        'productInfo' => {
          'name' => 'Short Ribs',
          'brand' => { 'name' => 'ACME' },
          'packSize' => { 'pack' => '4', 'size' => '5 LB' },
          'images' => ['', 'https://mediacdn.sysco.com/a.jpg', 'https://mediacdn.sysco.com/b.jpg'],
          'isOrderable' => true
        },
        'availableStockInfo' => { 'stockIndicator' => 'S' }
      }

      out = scraper.send(:parse_search_result, result, {})
      expect(out[:image_url]).to eq('https://mediacdn.sysco.com/a.jpg')
    end

    it 'leaves image_url nil when images is empty' do
      result = { 'productId' => '9', 'productInfo' => { 'name' => 'X', 'images' => [] },
                 'availableStockInfo' => { 'stockIndicator' => 'S' } }
      expect(scraper.send(:parse_search_result, result, {})[:image_url]).to be_nil
    end
  end

  describe Scrapers::WhatChefsWantScraper, '#format_api_product' do
    subject(:scraper) { described_class.allocate }

    it 'captures canonicalProduct.thumbnail.url' do
      product = { 'itemCode' => '02550', 'description' => 'Buttermilk', 'brandName' => 'Dairy Direct',
                  'thumbnail' => { 'url' => 'https://fsa-assets.s3.amazonaws.com/x.jpg' } }
      expect(scraper.send(:format_api_product, product)[:image_url])
        .to eq('https://fsa-assets.s3.amazonaws.com/x.jpg')
    end

    it 'is nil without a thumbnail' do
      product = { 'itemCode' => '1', 'description' => 'No Image' }
      expect(scraper.send(:format_api_product, product)[:image_url]).to be_nil
    end
  end

  describe Scrapers::ChefsWarehouseApi, '#parse_search_product' do
    subject(:api) { described_class.allocate }

    it 'captures imageUrl from a search node' do
      product = { 'sku' => 'X1', 'description' => 'Manchego',
                  'imageUrl' => 'https://cdn.pimber.ly/x.jpg', 'variants' => [{}] }
      expect(api.send(:parse_search_product, product)[:image_url]).to eq('https://cdn.pimber.ly/x.jpg')
    end
  end
end
