require 'rails_helper'

# "<Supplier> changed your order" — sent when an order went through but isn't
# what the chef asked for (Carmin's alerting rule, Oct 3 2026). Oct 2026 adds
# Premiere Produce splits: items that DO come, on a later day.
RSpec.describe OrderMailer, type: :mailer do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier, name: 'Premiere Produce One') }
  let(:order) do
    create(:order, user: user, supplier: supplier, organization: user.current_organization,
                   status: 'submitted', delivery_date: Date.new(2026, 10, 20), supplier_exceptions: exceptions)
  end

  context 'when items only moved to a later day' do
    let(:exceptions) do
      [{ 'sku' => '01298', 'name' => 'Bone Marrow', 'type' => 'delivery_changed', 'ordered' => 1, 'filled' => 1,
         'message' => 'Arrives Wed Oct 28 — Premiere Produce put it on a separate order' }]
    end

    it 'says they arrive later instead of "not coming"' do
      mail = described_class.supplier_changed_order(order)

      expect(mail.subject).to include('1 item arrives on a later day')
      body = mail.body.encoded
      expect(body).to include('will deliver these items on a later day', 'Bone Marrow', 'Arrives Wed Oct 28', 'Arrives later')
      expect(body).not_to include("can't send everything you ordered")
    end
  end

  context 'when an item is not coming' do
    let(:exceptions) do
      [{ 'sku' => '1', 'name' => 'Walnuts', 'type' => 'out_of_stock', 'ordered' => 2, 'filled' => 0, 'message' => 'Out of stock' }]
    end

    it 'keeps the existing wording' do
      mail = described_class.supplier_changed_order(order)

      expect(mail.subject).to include('1 item not coming')
      expect(mail.body.encoded).to include("can't send everything you ordered")
    end
  end
end
