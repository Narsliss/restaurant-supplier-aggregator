module PriceClassifiers
  class Base
    # Map supplier codes to classifier classes. New suppliers fall through
    # to Base (generic behavior). To add a supplier-specific override:
    #   1. Create app/services/price_classifiers/new_supplier.rb
    #   2. Define class NewSupplier < Base with skip_inference? override
    #   3. Add the supplier code mapping here
    REGISTRY = {
      "premiereproduceone"  => "PriceClassifiers::PremiereProduceOne",
      "whatchefswant"       => "PriceClassifiers::WhatChefsWant",
      "usfoods"             => "PriceClassifiers::UsFoods",
      "sysco"               => "PriceClassifiers::Sysco",
      "chefswarehouse"      => "PriceClassifiers::ChefsWarehouse",
      "email-blue-ribbon-6" => "PriceClassifiers::BlueRibbon"
    }.freeze

    def self.for(item)
      code = item.supplier&.code
      klass_name = REGISTRY[code]
      klass = klass_name ? klass_name.constantize : self
      klass.new(item)
    end

    attr_reader :item

    def initialize(item)
      @item = item
    end

    # Returns a normalized unit string ("lb", "oz", "kg") when the stored
    # price is per-unit, or nil when the price is for the whole pack/case.
    def inferred_price_unit
      return nil unless item.pack_size.present?
      return nil if skip_inference?

      detect_variable_weight_unit
    end

    private

    def pack_size
      item.pack_size
    end

    def supplier
      item.supplier
    end

    def case_pricing?
      supplier&.case_pricing?
    end

    # Subclasses override to add supplier-specific skip conditions.
    # Call super first — base guards apply to all case-pricing suppliers.
    def skip_inference?
      return false unless case_pricing?
      return true if item.price.blank?
      return true if item.source == "catalog_search"
      false
    end

    # Generic variable-weight detection patterns shared across suppliers.
    # Subclasses can override to add or restrict patterns.
    def detect_variable_weight_unit
      # Suppliers separate the size from the variable-weight marker with a
      # space, a hyphen, or nothing at all ("5# UP", "12x5#-UP", "24x8OZAVG").
      # SEP matches all three: requiring whitespace read Sysco's "12x5#-UP"
      # beef tenderloin as a fixed 60 lb case and compared a per-pound quote
      # across the whole pack.
      sep = /[\s-]*/

      # "15 LB+" or "5 OZ+" — plus sign means variable weight
      if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)#{sep}\+/i
        return $1.downcase
      end

      # "10#+" or "10#-+" — pound-sign with plus
      if pack_size =~ /\d+\.?\d*\s*##{sep}\+/i
        return "lb"
      end

      # "12LB AVG", "5LB UP AVG" or "24x8OZAVG" — average weight means per-unit pricing
      if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)#{sep}(?:\w+\s+)?AVG/i
        return $1.downcase
      end

      # "10#avg", "5# AVG" or "5#-AVG" — pound-sign with AVG
      if pack_size =~ /\d+\.?\d*\s*##{sep}AVG/i
        return "lb"
      end

      # "5#UP", "5# UP" or "12x5#-UP" — pound-sign with UP (minimum weight)
      if pack_size =~ /\d+\.?\d*\s*##{sep}UP/i
        return "lb"
      end

      # A weight RANGE is the same statement as AVG, written differently:
      # "14x3-3.50 LB", "8x7-10# LB", "2x10-14# LB" all mean each piece lands
      # somewhere in that band, so the price is a rate per pound. Sysco writes
      # its catch-weight proteins this way far more often than it writes AVG,
      # and reading them as case totals put whole chickens at $0.04/lb and
      # boneless pork butt at $0.03/lb.
      #
      # A multi-piece pack whose per-piece weight is given as a band —
      # "8x7-10# LB" is eight pieces of 7-10 lb, billed per pound.
      #
      # Three guards, each earned from a real row that read wrong:
      #   * multiplier >= 2. "1x18-24#" is ONE container weighing 18-24 lb, a
      #     case price. Zucchini read as per-lb came out at $586.95.
      #   * no "PC". "1x4-5 PC" counts pieces, not pounds.
      #   * the second number is the larger, so a hyphenated product code or a
      #     PPO "BAG - 1-5#" container count cannot match.
      if pack_size !~ /\bPC\b/i &&
         pack_size =~ /(\d+\.?\d*)\s*[x\/]\s*(\d+\.?\d*)\s*-\s*(\d+\.?\d*)\s*(?:#|LB\b)/i &&
         $1.to_f >= 2 && $3.to_f > $2.to_f
        return "lb"
      end

      nil
    end
  end
end
