# Stands in for a supplier API client whose login can switch restaurants
# (see Suppliers::RestaurantSwitcher). Records every switch; `ignore_switch`
# simulates a supplier that silently stays where it was.
class FakeRestaurantApi
  attr_accessor :current, :ignore_switch, :restaurants
  attr_reader :switches

  def initialize(current:, restaurants: [])
    @current = current.to_s
    @restaurants = restaurants
    @switches = []
    @ignore_switch = false
  end

  def ensure_session! = true
  def list_restaurants = restaurants

  # US Foods shape
  def switch_customer!(customer_number, _division)
    record(customer_number)
  end

  def token_customer_number = current

  # Chef's Warehouse shape
  def set_organization!(id)
    record(id)
  end

  def current_ship_to = current

  # What Chefs Want shape
  def switch_company!(id)
    record(id)
  end

  def current_company_id = current

  private

  def record(id)
    @switches << id.to_s
    @current = id.to_s unless ignore_switch
    true
  end
end
