require 'rails_helper'

# Operations page: the morning stock panel and the per-supplier mode switch
# (plan Phase 3, Oct 2026).
RSpec.describe 'Admin operations — morning stock', type: :request do
  let(:super_admin) do
    User.where(role: 'super_admin').destroy_all
    create(:user, :super_admin)
  end
  let!(:supplier) { create(:supplier, name: 'Stock Test Foods', morning_stock_mode: 'shadow') }

  before { sign_in super_admin }

  it 'shows each supplier with its mode and the stuck-syncing count' do
    get admin_operations_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Morning stock', 'Stock Test Foods', 'shadow')
  end

  it 'shows page-only notes and the items a supplier sends no stock for' do
    sp = create(:supplier_product, supplier: supplier)
    create(:supplier_list_item, supplier_list: create(:supplier_list, supplier: supplier), supplier_product: sp)
    supplier.update!(last_stock_run: { 'at' => Time.current.iso8601, 'kind' => 'catalog', 'errors' => [],
                                       'crawl' => { 'fetched' => 100, 'expected' => 120, 'short' => [], 'failed' => [],
                                                    'capped' => ['Supplies'], 'capped_fetched' => 80, 'capped_expected' => 100 },
                                       'list_no_stock_data_ids' => [sp.id] })

    get admin_operations_path

    expect(response.body).to include('Supplies stopped at the 10,000-item category limit', '1 no stock sent')
  end

  it 'switches a supplier to live' do
    patch stock_mode_admin_operations_path, params: { supplier_id: supplier.id, mode: 'live' }

    expect(response).to redirect_to(admin_operations_path)
    expect(supplier.reload.morning_stock_mode).to eq('live')
  end

  it 'refuses a mode it does not know' do
    patch stock_mode_admin_operations_path, params: { supplier_id: supplier.id, mode: 'everything' }

    expect(supplier.reload.morning_stock_mode).to eq('shadow')
    expect(flash[:alert]).to include('Unknown mode')
  end

  it 'is closed to everyone but super admins' do
    sign_out super_admin
    sign_in create(:user, :fully_onboarded)

    patch stock_mode_admin_operations_path, params: { supplier_id: supplier.id, mode: 'live' }

    expect(supplier.reload.morning_stock_mode).to eq('shadow')
  end

  it 'only accepts off, shadow or live on the supplier itself' do
    expect(supplier.update(morning_stock_mode: 'maybe')).to be(false)
    expect(Supplier.new.morning_stock_mode).to eq('live')
  end
end
