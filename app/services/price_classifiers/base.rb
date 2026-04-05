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
      # "15 LB+" or "5 OZ+" — plus sign means variable weight
      if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)\s*\+/i
        return $1.downcase
      end

      # "10#+" — pound-sign with plus
      if pack_size =~ /\d+\.?\d*\s*#\s*\+/i
        return "lb"
      end

      # "12LB AVG" or "5LB UP AVG" — average weight means per-unit pricing
      if pack_size =~ /\d+\.?\d*\s*(LB|OZ|KG)\s+(?:\w+\s+)?AVG/i
        return $1.downcase
      end

      # "10#avg" or "5# AVG" — pound-sign with AVG
      if pack_size =~ /\d+\.?\d*\s*#\s*AVG/i
        return "lb"
      end

      # "5#UP" or "5# UP" — pound-sign with UP (minimum weight)
      if pack_size =~ /\d+\.?\d*\s*#\s*UP/i
        return "lb"
      end

      nil
    end
  end
end
