# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (PRD: Product Image Thumbnails): the import sink persists the captured
# image URL and sets image_status so the lazy mirror job knows what to fetch.
RSpec.describe ImportSupplierProductsService, 'image capture' do
  let(:supplier)   { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:service)    { described_class.new(credential) }

  def prep!(existing: {})
    service.instance_variable_set(:@existing_by_sku, existing)
    service.instance_variable_set(:@product_index, service.send(:build_product_index, []))
    service.instance_variable_set(:@seen_skus, Set.new)
    service.instance_variable_set(:@items_processed, 0)
  end

  it 'stores image_source_url and marks pending for a new item with an image' do
    prep!
    service.send(:import_batch, [{ supplier_sku: 'A1', supplier_name: 'Short Ribs',
                                   image_url: 'https://cdn.example/x.jpg' }])

    sp = SupplierProduct.find_by(supplier: supplier, supplier_sku: 'A1')
    expect(sp.image_source_url).to eq('https://cdn.example/x.jpg')
    expect(sp.image_status).to eq('pending')
  end

  it 'marks none for a new item without an image' do
    prep!
    service.send(:import_batch, [{ supplier_sku: 'A2', supplier_name: 'Celery' }])

    sp = SupplierProduct.find_by(supplier: supplier, supplier_sku: 'A2')
    expect(sp.image_status).to eq('none')
    expect(sp.image_source_url).to be_nil
  end

  it 're-pends an existing item when the image url changes' do
    existing = SupplierProduct.create!(supplier: supplier, supplier_sku: 'A3', supplier_name: 'Carrots',
                                       image_source_url: 'https://cdn.example/old.jpg', image_status: 'mirrored')
    prep!(existing: { 'A3' => existing })

    service.send(:import_batch, [{ supplier_sku: 'A3', supplier_name: 'Carrots',
                                   image_url: 'https://cdn.example/new.jpg' }])

    expect(existing.reload.image_source_url).to eq('https://cdn.example/new.jpg')
    expect(existing.image_status).to eq('pending')
  end

  it 'preserves a mirrored status when the url is unchanged' do
    existing = SupplierProduct.create!(supplier: supplier, supplier_sku: 'A4', supplier_name: 'Kale',
                                       image_source_url: 'https://cdn.example/same.jpg', image_status: 'mirrored')
    prep!(existing: { 'A4' => existing })

    service.send(:import_batch, [{ supplier_sku: 'A4', supplier_name: 'Kale',
                                   image_url: 'https://cdn.example/same.jpg' }])

    expect(existing.reload.image_status).to eq('mirrored')
  end
end
