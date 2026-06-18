require 'rails_helper'

# The matching modal polls this endpoint to swap placeholder thumbnails for
# their real (async-mirrored) image without a reopen.
RSpec.describe 'ProductImages', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:supplier) { create(:supplier) }

  before { sign_in owner }

  let(:mirrored) do
    sp = create(:supplier_product, supplier: supplier, image_status: 'mirrored')
    sp.thumbnail.attach(io: StringIO.new('x'), filename: 't.jpg', content_type: 'image/jpeg')
    sp
  end

  let(:unmirrored) do
    create(:supplier_product, supplier: supplier, image_status: 'pending',
                              image_source_url: 'https://cdn.example/x.jpg')
  end

  it 'returns served URLs only for products that have finished mirroring' do
    get '/product_images/resolve', params: { ids: "#{mirrored.id},#{unmirrored.id}" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.keys).to contain_exactly(mirrored.id.to_s)
    expect(body[mirrored.id.to_s]).not_to start_with('data:')
  end

  it 'returns an empty object when no ids are given' do
    get '/product_images/resolve'
    expect(JSON.parse(response.body)).to eq({})
  end

  it 'is display-only: polling never enqueues a mirror job' do
    expect do
      get '/product_images/resolve', params: { ids: unmirrored.id.to_s }
    end.not_to have_enqueued_job(MirrorProductImageJob)
  end
end
