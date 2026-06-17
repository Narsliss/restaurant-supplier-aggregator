# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProductImagesHelper, type: :helper do
  let(:supplier) { create(:supplier) }
  let(:sp) do
    create(:supplier_product, supplier: supplier, supplier_sku: 'S1', supplier_name: 'Kale',
                              image_source_url: 'https://cdn.example/k.jpg', image_status: 'pending')
  end

  around do |example|
    prev = ENV.to_hash.slice('PRODUCT_IMAGES_ENABLED', 'R2_PUBLIC_HOST')
    ENV['PRODUCT_IMAGES_ENABLED'] = 'true'
    ENV['R2_PUBLIC_HOST'] = 'images.enplacepro.app'
    example.run
    ENV['PRODUCT_IMAGES_ENABLED'] = prev['PRODUCT_IMAGES_ENABLED']
    ENV['R2_PUBLIC_HOST'] = prev['R2_PUBLIC_HOST']
  end

  it 'returns a placeholder for a nil product' do
    expect(helper.product_thumb_url(nil)).to start_with('data:image/svg+xml')
  end

  it 'returns the R2 public URL when a thumbnail is attached' do
    sp.thumbnail.attach(io: StringIO.new('x'), filename: 't.jpg', content_type: 'image/jpeg')
    url = helper.product_thumb_url(sp)
    expect(url).to eq("https://images.enplacepro.app/#{sp.thumbnail.key}")
  end

  it 'enqueues the mirror job on a pending miss and returns a placeholder' do
    expect { @result = helper.product_thumb_url(sp) }
      .to have_enqueued_job(MirrorProductImageJob).with(sp.id)
    expect(@result).to start_with('data:image/svg+xml')
  end

  it 'does not enqueue when the feature flag is off' do
    ENV['PRODUCT_IMAGES_ENABLED'] = 'false'
    expect { helper.product_thumb_url(sp) }.not_to have_enqueued_job(MirrorProductImageJob)
  end

  it 'does not re-enqueue a recent "none"' do
    sp.update!(image_status: 'none', image_checked_at: 1.hour.ago)
    expect { helper.product_thumb_url(sp) }.not_to have_enqueued_job(MirrorProductImageJob)
  end

  it 're-enqueues a "failed" older than the failed TTL' do
    sp.update!(image_status: 'failed', image_checked_at: 2.days.ago)
    expect { helper.product_thumb_url(sp) }.to have_enqueued_job(MirrorProductImageJob)
  end
end
