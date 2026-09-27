require "rails_helper"

# Suppliers that publish their own delivery days (Performance, Sysco): a date
# they won't deliver on can't be submitted (Carmin, Sep 27 2026: "shouldn't the
# submit order button be greyed out with a bad date picked?"). The review page
# greys the button (JS); this pins the server-side refusal behind it.
RSpec.describe "Submitting an order for a non-delivery day", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    create(:membership, user: user, organization: organization, role: "chef", active: true).membership_locations.create!(location: location)
    create(:subscription, user: user, organization_id: organization.id)
    user
  end
  let(:performance) { Supplier.find_by(code: "performance") || create(:supplier, name: "Performance", code: "performance") }
  let!(:login) do
    create(:supplier_credential, user: chef, organization: organization, location: location, supplier: performance, status: "active",
                                 available_delivery_dates: %w[2026-09-29 2026-10-02 2026-10-06])
  end
  let(:order) do
    create(:order, user: chef, supplier: performance, organization: organization, location: location,
                   status: "draft", batch_id: "batch-1", delivery_date: Date.new(2026, 10, 1))
  end

  before do
    travel_to Time.zone.local(2026, 9, 27, 12)
    sign_in chef
    post switch_location_path, params: { location_id: location.id }
  end

  after { travel_back }

  def submit
    post submit_batch_orders_path, params: { batch_id: "batch-1", order_ids: [order.id] }
  end

  it "refuses a day Performance doesn't deliver, naming the next delivery day" do
    expect { submit }.not_to have_enqueued_job(PlaceOrderJob)

    expect(order.reload.status).to eq("draft")
    expect(flash[:alert]).to include("doesn't deliver on Thu Oct 1", "next delivery Fri Oct 2")
  end

  it "refuses any date when Performance says the account isn't set up for deliveries" do
    login.update!(available_delivery_dates: [], delivery_dates_error: "You are not currently set up for deliveries.")
    order.update!(delivery_date: Date.new(2026, 10, 2))

    expect { submit }.not_to have_enqueued_job(PlaceOrderJob)
    expect(flash[:alert]).to include("not currently set up for deliveries")
  end

  it "places the order on a delivery day" do
    order.update!(delivery_date: Date.new(2026, 10, 2))

    expect { submit }.to have_enqueued_job(PlaceOrderJob).with(order.id)
  end

  it "doesn't block when no delivery days are known for the login" do
    login.update!(available_delivery_dates: [])

    expect { submit }.to have_enqueued_job(PlaceOrderJob).with(order.id)
  end
end
