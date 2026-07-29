require 'rails_helper'

RSpec.describe ProduceWeightEstimator do
  describe '.piece_lbs' do
    it 'knows standard produce piece weights' do
      expect(described_class.piece_lbs('BAKER POTATOES PremierProduce One')).to eq(0.7)
      expect(described_class.piece_lbs('lime 10 lb')).to eq(0.2)
      expect(described_class.piece_lbs('Red Pepper Bell')).to eq(0.45)
    end

    it 'prefers compound names over their substrings' do
      expect(described_class.piece_lbs('12-16 OZ SWEET POTATOES')).to eq(0.85)
      expect(described_class.piece_lbs('GREEN PEPPER BELL')).to eq(0.45)
    end

    it 'returns nil for unrecognized products' do
      expect(described_class.piece_lbs('Monogram Fuel, Chafing Can 6 Hour')).to be_nil
      expect(described_class.piece_lbs(nil)).to be_nil
      expect(described_class.piece_lbs('')).to be_nil
    end
  end

  describe '.pint_basket_lbs' do
    it 'recognizes pint-basket produce' do
      expect(described_class.pint_basket_lbs('Tomato Cherry Heirloom')).to eq(0.75)
      expect(described_class.pint_basket_lbs('MIXED HEIRLOOM CHERRY TOMATOES')).to eq(0.75)
      expect(described_class.pint_basket_lbs('Strawberries Driscoll')).to eq(1.0)
    end

    it 'returns nil for non-basket products' do
      expect(described_class.pint_basket_lbs('Half & Half Pint Cartons')).to be_nil
      expect(described_class.pint_basket_lbs('Beefsteak Tomato Layered')).to be_nil
    end
  end
end
