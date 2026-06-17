# frozen_string_literal: true

require 'rails_helper'
require 'base64'

RSpec.describe MirrorProductImageJob do
  let(:supplier) { create(:supplier) }
  let(:url) { 'https://cdn.example/img.png' }
  let(:sp) do
    create(:supplier_product, supplier: supplier, supplier_sku: 'SKU1', supplier_name: 'Short Ribs',
                              image_source_url: url, image_status: 'pending')
  end

  # 1x1 PNG
  let(:png) do
    Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
  end

  def run = described_class.new.perform(sp.id)

  context 'with a valid image response' do
    before { stub_request(:get, url).to_return(status: 200, body: png, headers: { 'Content-Type' => 'image/png' }) }

    it 'mirrors a JPEG thumbnail and marks mirrored' do
      run
      sp.reload
      expect(sp.thumbnail).to be_attached
      expect(sp.thumbnail.content_type).to eq('image/jpeg')
      expect(sp.image_status).to eq('mirrored')
      expect(sp.image_checked_at).to be_present
    end
  end

  context 'with a non-image response' do
    before { stub_request(:get, url).to_return(status: 200, body: '<html>', headers: { 'Content-Type' => 'text/html' }) }

    it 'marks none and attaches nothing' do
      run
      sp.reload
      expect(sp.thumbnail).not_to be_attached
      expect(sp.image_status).to eq('none')
    end
  end

  context 'with a 404' do
    before { stub_request(:get, url).to_return(status: 404) }

    it 'marks none' do
      run
      expect(sp.reload.image_status).to eq('none')
    end
  end

  context 'with a network error' do
    before { stub_request(:get, url).to_raise(Faraday::ConnectionFailed) }

    it 'marks failed (transient)' do
      run
      expect(sp.reload.image_status).to eq('failed')
    end
  end

  context 'when already mirrored (dedup)' do
    before do
      sp.thumbnail.attach(io: StringIO.new(png), filename: 'x.jpg', content_type: 'image/jpeg')
      sp.update!(image_status: 'mirrored')
    end

    it 'does not download again' do
      run
      expect(a_request(:get, url)).not_to have_been_made
    end
  end

  context 'when image_source_url is blank' do
    before { sp.update!(image_source_url: nil) }

    it 'no-ops' do
      expect { run }.not_to change { sp.reload.image_status }
      expect(a_request(:get, url)).not_to have_been_made
    end
  end
end
