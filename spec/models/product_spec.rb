require 'rails_helper'

RSpec.describe Product, type: :model do
  describe 'validations' do
    it 'requires name' do
      expect(build(:product, name: nil)).not_to be_valid
    end
  end

  describe 'before_save :set_normalized_name' do
    it 'lowercases, strips punctuation, and squishes whitespace' do
      product = create(:product, name: "Chef's Choice  Tomato!! 28oz")
      expect(product.normalized_name).to eq('chefs choice tomato 28oz')
    end
  end

  describe '#supplier_product_for' do
    let(:product) { create(:product) }
    let(:supplier_a) { create(:supplier) }
    let(:supplier_b) { create(:supplier) }
    let!(:sp_a) { create(:supplier_product, product: product, supplier: supplier_a) }
    let!(:sp_b) { create(:supplier_product, product: product, supplier: supplier_b) }

    it 'returns the matching supplier_product when given a Supplier' do
      expect(product.supplier_product_for(supplier_a)).to eq(sp_a)
      expect(product.supplier_product_for(supplier_b)).to eq(sp_b)
    end

    it 'accepts a supplier_id integer' do
      expect(product.supplier_product_for(supplier_a.id)).to eq(sp_a)
    end

    it 'uses detect (preloaded association) — no extra DB query when eager-loaded' do
      eager = Product.includes(:supplier_products).find(product.id)
      expect {
        eager.supplier_product_for(supplier_a)
      }.not_to(change { ActiveRecord::Base.connection.query_cache.size })
    end
  end

  describe '#price_for' do
    let(:product) { create(:product) }
    let(:supplier) { create(:supplier) }

    it 'returns the current_price for the supplier' do
      create(:supplier_product, product: product, supplier: supplier, current_price: 9.99)
      expect(product.price_for(supplier)).to eq(9.99)
    end

    it 'returns nil when supplier has no listing' do
      expect(product.price_for(supplier)).to be_nil
    end
  end

  describe '#price_range' do
    let(:product) { create(:product) }

    it 'returns min/max/spread across all priced supplier_products' do
      create(:supplier_product, product: product, current_price: 5.00)
      create(:supplier_product, product: product, current_price: 12.00)
      create(:supplier_product, product: product, current_price: 8.00)

      expect(product.price_range).to eq(min: 5.00, max: 12.00, spread: 7.00)
    end

    it 'returns nil when no supplier_products are priced' do
      create(:supplier_product, product: product, current_price: nil)
      expect(product.price_range).to be_nil
    end
  end

  describe '.search' do
    before do
      create(:product, name: 'Tomato Paste', normalized_name: 'tomato paste')
      create(:product, name: 'Crushed Tomato', normalized_name: 'crushed tomato')
      create(:product, name: 'Chicken Breast', normalized_name: 'chicken breast')
    end

    it 'returns products where every term matches name, normalized_name, or upc' do
      results = Product.search('tomato').pluck(:name)
      expect(results).to include('Tomato Paste', 'Crushed Tomato')
      expect(results).not_to include('Chicken Breast')
    end

    it 'requires every term to match (AND, not OR)' do
      results = Product.search('chicken tomato').pluck(:name)
      expect(results).to be_empty
    end

    it 'returns none for blank query' do
      expect(Product.search('')).to be_empty
      expect(Product.search('   ')).to be_empty
    end
  end
end
