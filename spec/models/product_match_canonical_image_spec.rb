# frozen_string_literal: true

require 'rails_helper'

# PRD2 P1: canonical image resolution + validation on ProductMatch.
RSpec.describe ProductMatch, 'canonical image' do
  describe '#canonical_image_source' do
    let(:match) { described_class.new(match_status: 'manual') }
    let(:primary_sp) { SupplierProduct.new(id: 1) }
    let(:chosen_sp) { SupplierProduct.new(id: 2) }

    before do
      allow(match).to receive(:primary_item).and_return(double(supplier_product: primary_sp))
    end

    it 'falls back to the primary item product when no explicit choice' do
      expect(match.canonical_image_source).to eq(primary_sp)
    end

    it 'prefers the explicitly chosen supplier product' do
      match.canonical_image_supplier_product = chosen_sp
      expect(match.canonical_image_source).to eq(chosen_sp)
    end

    it 'is nil when there is neither a choice nor a primary item' do
      allow(match).to receive(:primary_item).and_return(nil)
      expect(match.canonical_image_source).to be_nil
    end
  end

  describe 'validation: canonical image must belong to the match' do
    let(:match) { described_class.new(match_status: 'manual') }
    let(:in_match) { SupplierProduct.new(id: 5) }

    before { allow(match).to receive(:canonical_image_choices).and_return([in_match]) }

    it 'accepts a supplier product that is one of the match items' do
      match.canonical_image_supplier_product_id = 5
      match.valid?
      expect(match.errors[:canonical_image_supplier_product_id]).to be_empty
    end

    it 'rejects a supplier product not in the match' do
      match.canonical_image_supplier_product_id = 999
      match.valid?
      errs = match.errors[:canonical_image_supplier_product_id]
      expect(errs).not_to be_empty
      expect(errs.first.to_s).to include('must be one of')
    end

    it 'allows a nil canonical image (uses the primary fallback)' do
      match.canonical_image_supplier_product_id = nil
      match.valid?
      expect(match.errors[:canonical_image_supplier_product_id]).to be_empty
    end
  end
end
