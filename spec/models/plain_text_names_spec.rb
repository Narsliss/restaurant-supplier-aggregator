require "rails_helper"

# Names with links / < > are rejected when NEW or CHANGED only. Existing rows
# must keep saving, so a legacy name can never break an unrelated update.
RSpec.describe "Plain-text names on User, Organization, Location" do
  let(:bad) { '<a href="https://myxa.cc/">SCAM</a>' }

  describe User do
    it "rejects a bad first or last name on create" do
      expect(build(:user, first_name: bad)).not_to be_valid
      expect(build(:user, last_name: "see https://spam.example")).not_to be_valid
    end

    it "rejects renaming to a bad name" do
      user = create(:user)
      expect(user.update(first_name: bad)).to be(false)
    end

    it "still saves an existing user whose legacy name is bad" do
      user = create(:user)
      user.update_columns(first_name: bad)
      expect(user.reload.update(phone: "555-0100")).to be(true)
    end
  end

  describe Organization do
    it "rejects a bad name on create and rename" do
      expect(build(:organization, name: bad)).not_to be_valid
      org = create(:organization)
      expect(org.update(name: "www.spam.example")).to be(false)
    end

    it "still saves an existing org whose legacy name is bad" do
      org = create(:organization)
      org.update_columns(name: bad)
      expect(org.reload.update(phone: "555-0100")).to be(true)
    end
  end

  describe Location do
    let(:org) { create(:organization) }

    it "rejects a bad name on create and rename" do
      expect(build(:location, organization: org, name: bad)).not_to be_valid
      loc = create(:location, organization: org)
      expect(loc.update(name: "<b>Main</b>")).to be(false)
    end

    it "still saves an existing location whose legacy name is bad" do
      loc = create(:location, organization: org)
      loc.update_columns(name: bad)
      expect(loc.reload.update(phone: "555-0100")).to be(true)
    end
  end
end
