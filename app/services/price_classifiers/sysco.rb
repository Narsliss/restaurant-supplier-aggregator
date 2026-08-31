module PriceClassifiers
  class Sysco < Base
    private

    # Sysco quotes a catalog price exactly the way it quotes an order-guide
    # price: catch-weight items carry a rate per pound, not a case total.
    #
    # Base skips inference on catalog-search rows because for the other
    # case-pricing suppliers a catalog price really is a case price. Here it
    # never is, and skipping split the same item two ways depending only on how
    # it reached the list — a 16 lb case of pork tenderloin quoted at $3.16/lb
    # read as $0.20/lb from a catalog search and $3.16/lb from an order guide.
    # Sysco then undercut every competitor by the weight of the pack.
    #
    # A blank price still skips: there is no number here to label, and
    # SupplierListItem borrows the product's own unit along with its price.
    def skip_inference?
      return false unless case_pricing?

      item.price.blank?
    end
  end
end
