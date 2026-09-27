require "rails_helper"

# best_similarity now scores precomputed token sets (so the matcher can clean
# each name once per run). The score must be exactly what it always was.
RSpec.describe ProductNormalizer, ".best_similarity" do
  pairs = [
    ["Sour Cream", "Glenview Farms Sour Cream, Cultured All Natural Tub Ref"],
    ["PACKER - TOMATO, HEIRLOOM FRESH REF", "Tomato - 5X6 Vine Ripe"],
    ["Olive Oil Extra Virgin", "ROMA - OIL OLIVE EXTRA VIRGIN TIN"],
    ["Half & Half", "Puree Mango"],
    ["", "Lemons"]
  ]

  pairs.each do |a, b|
    it "scores #{a.inspect} vs #{b.inspect} the same from cached token sets" do
      expect(described_class.best_similarity_of_sets(described_class.token_set(a), described_class.token_set(b)))
        .to eq(described_class.best_similarity(a, b))
    end
  end
end
