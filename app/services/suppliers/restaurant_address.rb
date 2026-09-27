module Suppliers
  # Comparing a supplier's restaurant with an EnPlace location for automatic
  # linking. Only the street number and 5-digit zip are compared: suppliers
  # disagree on city names (US Foods calls D'oro "Blue Ash", PPO calls it
  # "Montgomery" — both 45242) and on street spelling ("Ave" / "Avenue").
  module RestaurantAddress
    module_function

    def street_number(street)
      street.to_s[/\A\s*(\d+[A-Za-z]?)\b/, 1]&.upcase
    end

    # "45208", "45208-1234", "452081234" and "OH 45208" all give "45208".
    def zip5(zip)
      zip.to_s[/\d{5}/]
    end

    # "2724|45208", or nil when either part is missing (no certain match).
    def key(street, zip)
      number = street_number(street)
      five = zip5(zip)
      "#{number}|#{five}" if number && five
    end

    # "2724 Erie Ave, Cincinnati, OH 45208, USA" -> street/city/zip.
    # "Montgomery, OH 45242, USA" has no street.
    def parse(one_line)
      parts = one_line.to_s.split(',').map(&:strip).reject(&:empty?)
      parts.pop if parts.last.to_s.match?(/\A(USA|US|United States)\z/i)
      state_zip = parts.pop.to_s
      city = parts.pop
      { street: parts.join(', ').presence, city: city, zip: zip5(state_zip) }
    end

    # For exact-name matching (Chef's Warehouse): "D'ORO" == "D'oro".
    def normalized_name(name)
      name.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end
