require "rails_helper"

RSpec.describe UnitOverride do
  describe "#stale_against?" do
    subject(:override) do
      described_class.new(net_weight_oz: 448, basis: "per_pack", pack_size_fingerprint: "1 BUSHEL")
    end

    # A supplier reformatting their own shorthand changed nothing about the box,
    # and crying wolf on it would train chefs to ignore the warning.
    it "ignores cosmetic rewording when both sides parse the same" do
      expect(override.stale_against?("1 BU")).to be(false)
      expect(override.stale_against?("1 bushel")).to be(false)
    end

    it "flags a pack that actually changed size" do
      expect(override.stale_against?("2 BUSHEL")).to be(true)
    end

    it "flags a pack that changed unit entirely" do
      expect(override.stale_against?("20 LB")).to be(true)
    end

    # Sheets have no structure to compare, so the raw string is all there is.
    context "when the pack size does not parse" do
      subject(:override) do
        described_class.new(net_weight_oz: 11, basis: "per_piece", pack_size_fingerprint: "10 SHEET")
      end

      it "falls back to comparing the normalized raw string" do
        expect(override.stale_against?("10 SHEET")).to be(false)
        expect(override.stale_against?("10  sheet")).to be(false)
        expect(override.stale_against?("12 SHEET")).to be(true)
      end
    end

    it "treats a missing pack size as not stale rather than guessing" do
      expect(override.stale_against?(nil)).to be(false)
    end
  end

  describe "#total_oz_for" do
    it "returns the pack weight as-is on a per-pack basis" do
      override = described_class.new(basis: "per_pack", net_weight_oz: 448)
      expect(override.total_oz_for("1 BUSHEL")).to eq(448.0)
    end

    it "multiplies by the count on a per-piece basis" do
      override = described_class.new(basis: "per_piece", net_weight_oz: 11)
      expect(override.total_oz_for("10 SHEET")).to eq(110.0)
      expect(override.total_oz_for("24 CT")).to eq(264.0)
    end

    it "returns nil rather than guessing when it cannot count the pieces" do
      override = described_class.new(basis: "per_piece", net_weight_oz: 11)
      expect(override.total_oz_for("CASE")).to be_nil
    end
  end

  describe ".plausible_per_lb?" do
    it "accepts a real foodservice price" do
      expect(described_class.plausible_per_lb?(32.00, 448)).to be(true)
    end

    it "rejects weights absurd enough to be unambiguous" do
      expect(described_class.plausible_per_lb?(32.00, 4)).to be(false)        # $128/lb
      expect(described_class.plausible_per_lb?(32.00, 100_000)).to be(false)  # half a cent a pound
    end

    # Documented limitation, not an oversight. A chef typing 2.8 for 28 yields
    # $11.43/lb, which is an ordinary foodservice price — no automatic rail can
    # reject it without also rejecting real products. The entry preview showing
    # the resulting price beside the other suppliers is the only thing that
    # catches this class of mistake, which is why it is not decoration.
    it "cannot catch a ten-fold slip that still lands on a believable price" do
      expect(described_class.plausible_per_lb?(32.00, 44.8)).to be(true)
      expect(described_class.plausible_per_lb?(32.00, 4_480)).to be(true)
    end
  end
end
