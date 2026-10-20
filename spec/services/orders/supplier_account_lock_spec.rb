require 'rails_helper'

# Order placement safety (Oct 20 2026,
# docs/plan-order-placement-double-submit-and-account-lock.md). Real Postgres
# advisory locks; "another placement" holds them on its own connection.
RSpec.describe Orders::SupplierAccountLock do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier) }
  let(:location) { create(:location, organization: user.current_organization, user: user) }
  let(:credential) { create(:supplier_credential, user: user, supplier: supplier, username: ' Chef@Example.com ') }
  let(:order) { build(:order, user: user, supplier: supplier, location: location) }
  let(:other_connection) { ApplicationRecord.connection_pool.checkout }

  after do
    other_connection.execute('SELECT pg_advisory_unlock_all()')
    ApplicationRecord.connection_pool.checkin(other_connection)
  end

  def held_elsewhere(names_order, names_credential)
    described_class.new(names_order, names_credential).tap { |l| l.acquire(connection: other_connection) }
  end

  it 'names the restaurant at the supplier and the login, from local data only' do
    lock = described_class.new(order, credential)

    expect(lock.names).to eq(["restaurant:#{supplier.id}:#{location.id}", "login:#{supplier.id}:chef@example.com"])
  end

  it 'names only the restaurant when there is no login' do
    expect(described_class.new(order, nil).names).to eq(["restaurant:#{supplier.id}:#{location.id}"])
  end

  it 'finds the login placement will use' do
    credential

    expect(described_class.for(order).names).to include("login:#{supplier.id}:chef@example.com")
  end

  it 'takes and releases the locks' do
    lock = described_class.new(order, credential)

    expect(lock.acquire).to be(true)
    expect(lock.held?).to be(true)
    expect(described_class.new(order, credential).acquire(connection: other_connection)).to be(false)

    lock.release

    expect(lock.held?).to be(false)
    expect(described_class.new(order, credential).acquire(connection: other_connection)).to be(true)
  end

  it 'takes all of its locks or none' do
    other_restaurant = build(:order, user: user, supplier: supplier, location: create(:location, organization: user.current_organization, user: user))
    held_elsewhere(other_restaurant, credential) # same login, another restaurant

    lock = described_class.new(order, credential)

    expect(lock.acquire).to be(false)
    expect(lock.held?).to be(false)
    # The restaurant key it may have taken first was given back.
    expect(described_class.new(order, nil).acquire(connection: other_connection)).to be(true)
  end

  it 'does not block the same supplier login at another supplier' do
    held_elsewhere(order, credential)
    elsewhere = build(:order, user: user, supplier: create(:supplier), location: location)

    expect(described_class.new(elsewhere, create(:supplier_credential, user: user, supplier: elsewhere.supplier,
                                                                       username: 'chef@example.com')).acquire).to be(true)
  end

  # Jobs run with the query cache on; it once answered a repeated lock SELECT
  # from memory without asking Postgres (found while building this).
  it 'asks Postgres every time, even with the query cache on' do
    ApplicationRecord.cache do
      first = described_class.new(order, credential)
      expect(first.acquire).to be(true)
      first.release

      held_elsewhere(order, credential)
      expect(described_class.new(order, credential).acquire).to be(false)
    end
  end

  it 'notices when its session lost the locks (a silent reconnect)' do
    lock = described_class.new(order, credential)
    lock.acquire

    ApplicationRecord.connection.execute('SELECT pg_advisory_unlock_all()')

    expect(lock.held?).to be(false)
    expect { lock.release }.not_to raise_error
  end
end
