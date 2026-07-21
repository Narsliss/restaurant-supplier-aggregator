require 'rails_helper'

# Worker-memory-optimization: lazy product index + deterministic index release.
# Guards the two behaviors that keep the Solid Queue scraping worker from
# idling at import-peak RSS forever.
RSpec.describe ImportSupplierProductsService, 'memory hygiene' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:service) { described_class.new(credential) }

  let!(:existing_sp) do
    SupplierProduct.create!(
      supplier: supplier, supplier_sku: 'SKU-1', supplier_name: 'Chicken Breast',
      current_price: 50.0, pack_size: '4x10 LB', in_stock: true
    )
  end

  describe 'lazy product index' do
    it 'does not build the canonical-product index when the batch only updates existing SKUs' do
      service.send(:prepare_import_indexes!)
      service.send(:import_batch, [{ supplier_sku: 'SKU-1', supplier_name: 'Chicken Breast', current_price: 55.0 }])

      expect(service.instance_variable_get(:@product_index)).to be_nil
      expect(existing_sp.reload.current_price).to eq(55.0)
      expect(existing_sp.previous_price).to eq(50.0)
    end

    it 'builds the index on demand and still links new SKUs to canonical products' do
      canonical = Product.create!(name: 'Heavy Cream', normalized_name: 'heavy cream')
      service.send(:prepare_import_indexes!)
      service.send(:import_batch, [{ supplier_sku: 'SKU-2', supplier_name: 'Heavy Cream', current_price: 40.0, pack_size: '12x1 QT' }])

      expect(service.instance_variable_get(:@product_index)).not_to be_nil
      created = SupplierProduct.find_by(supplier_sku: 'SKU-2')
      expect(created).to be_present
      expect(created.product_id).to eq(canonical.id)
    end
  end

  describe '#release_import_indexes!' do
    it 'is public (jobs call it from ensure blocks) and clears the retained indexes' do
      service.send(:prepare_import_indexes!)
      service.send(:import_batch, [{ supplier_sku: 'SKU-2', supplier_name: 'Something New', current_price: 12.0 }])

      service.release_import_indexes!

      expect(service.instance_variable_get(:@existing_by_sku)).to be_nil
      expect(service.instance_variable_get(:@product_index)).to be_nil
      expect(service.instance_variable_get(:@seen_skus)).to be_nil
    end

    it 'does not break a subsequent run — indexes rebuild on demand' do
      service.send(:prepare_import_indexes!)
      service.release_import_indexes!

      service.send(:prepare_import_indexes!)
      service.send(:import_batch, [{ supplier_sku: 'SKU-1', supplier_name: 'Chicken Breast', current_price: 60.0 }])
      expect(existing_sp.reload.current_price).to eq(60.0)
    end
  end
end
