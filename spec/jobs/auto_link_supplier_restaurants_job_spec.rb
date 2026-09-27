require "rails_helper"

RSpec.describe AutoLinkSupplierRestaurantsJob do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:usfoods) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let(:performance) { Supplier.find_by(code: "performance") || create(:supplier, name: "Performance", code: "performance") }

  before { allow(Suppliers::RestaurantAutoLinker).to receive(:run_safely) }

  it "checks active picker-supplier logins, not Performance and not expired ones" do
    usf = create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, status: "active")
    create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, status: "active")
    create(:supplier_credential, user: create(:user), supplier: usfoods, organization_id: org.id, status: "expired")

    described_class.perform_now

    expect(Suppliers::RestaurantAutoLinker).to have_received(:run_safely).once.with(usf)
  end

  it "can check one organization's logins" do
    mine = create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, status: "active")
    other = create(:user, :with_organization)
    create(:supplier_credential, user: other, supplier: usfoods, organization_id: other.current_organization_id, status: "active")

    described_class.perform_now(nil, organization_id: org.id)

    expect(Suppliers::RestaurantAutoLinker).to have_received(:run_safely).once.with(mine)
  end

  describe "adding a restaurant" do
    it "re-checks the organization's logins once it has more than one restaurant" do
      create(:location, organization: org, user: owner)

      expect { create(:location, organization: org, user: owner) }
        .to have_enqueued_job(described_class).with(nil, organization_id: org.id)
    end

    it "does nothing for an organization's first restaurant" do
      expect { create(:location, organization: org, user: owner) }.not_to have_enqueued_job(described_class)
    end
  end
end
