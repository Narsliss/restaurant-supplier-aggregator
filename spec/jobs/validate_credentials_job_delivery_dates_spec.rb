require "rails_helper"

# Connecting a supplier that publishes its own delivery days fetches them as
# part of validation, so the order builder has them on the first visit
# (Carmin, Sep 27 2026: "why doesn't it happen automatically?").
RSpec.describe ValidateCredentialsJob, "delivery days on connect" do
  let(:manager) { instance_double(Authentication::SessionManager, validate_credentials: { valid: true }) }

  before do
    allow(Authentication::SessionManager).to receive(:new).and_return(manager)
    allow(Suppliers::RestaurantMatching).to receive(:record_count)
  end

  def connect(code)
    supplier = Supplier.find_by(code: code) || create(:supplier, code: code, name: code)
    credential = create(:supplier_credential, supplier: supplier, status: "pending")
    described_class.perform_now(credential.id)
    credential
  end

  it "fetches Performance's delivery days right away" do
    credential = nil
    expect { credential = connect("performance") }.to have_enqueued_job(FetchSyscoDeliveryDatesJob)
    expect(FetchSyscoDeliveryDatesJob).to have_been_enqueued.with(credential.id, force: true)
  end

  it "does nothing extra for suppliers without their own delivery days" do
    expect { connect("chefswarehouse") }.not_to have_enqueued_job(FetchSyscoDeliveryDatesJob)
  end
end
