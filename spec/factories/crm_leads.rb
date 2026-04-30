FactoryBot.define do
  factory :crm_lead, class: 'Crm::Lead' do
    association :salesperson, factory: %i[user salesperson]
    sequence(:restaurant_name) { |n| "Restaurant Lead #{n}" }
    contact_name { 'Chef A' }
    pipeline_stage { 'qualified' }
  end
end
