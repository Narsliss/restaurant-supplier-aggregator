module PriceClassifiers
  class WhatChefsWant < Base
    private

    def skip_inference?
      return true if super

      # "- Case" suffix (e.g., "15 LB AVG | CATELLI BROS - Case")
      # means the price is for the whole case.
      return true if pack_size =~ /-\s*Case\b/i

      # WCW LB-based patterns without "- Each" suffix are case-priced.
      # Two account formats:
      #   "6LB AVG | Packer - Each" → per-lb (has - Each)
      #   "6LB AVG"                 → case (no suffix)
      if pack_size =~ /\d+\.?\d*\s*LB/i && pack_size !~ /-\s*Each\b/i
        return true
      end

      false
    end
  end
end
