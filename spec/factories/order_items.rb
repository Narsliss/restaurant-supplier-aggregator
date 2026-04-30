FactoryBot.define do
  factory :order_item do
    order
    supplier_product
    quantity { 2 }
    unit_price { 12.50 }
    line_total { 25.00 }
    status { 'pending' }
    uom { 'case' }
  end
end
