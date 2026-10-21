# frozen_string_literal: true

require_relative 'demo_spec_helper'

RSpec.describe DemoMode::JobRunner do
  # Every job class this app has (app/jobs), by class name.
  let(:all_jobs) do
    Rails.root.glob('app/jobs/*.rb').map { |f| File.basename(f, '.rb').camelize } - ['ApplicationJob']
  end

  # Jobs that reach a supplier (scraper, supplier API, browser, supplier image
  # host) or only fan out to such jobs.
  let(:supplier_jobs) do
    %w[
      ValidateCredentialsJob RefreshSessionJob ImportSupplierProductsJob ImportSupplierListsJob
      SyscoCombinedImportJob DeepCatalogImportJob ScrapeSupplierJob PriceVerificationJob
      VerifyItemPriceJob PlaceOrderJob CheckOrderExceptionsJob FetchSyscoDeliveryDatesJob
      ChefsWarehouseCatalogPricingJob SyscoMarketplaceRemovalJob AutoLinkSupplierRestaurantsJob
      MirrorProductImageJob RefreshAllSessionsJob StaggeredSupplierImportJob StaggeredDeepImportJob
      SyncAllListsJob UsFoodsExceptionSweepJob
    ]
  end

  describe 'classification' do
    it 'has made a deliberate choice for every job in app/jobs' do
      lists = [described_class::LOCAL, DemoMode::Simulator::HANDLERS.keys,
               DemoMode::Simulator::NO_OUTCOME, described_class::DROPPED]
      undecided = all_jobs.reject { |name| lists.any? { |list| list.include?(name) } }
      twice = all_jobs.select { |name| lists.count { |list| list.include?(name) } > 1 }

      expect(undecided).to be_empty, "Decide how the demo treats: #{undecided.join(', ')} (demo/job_runner.rb)"
      expect(twice).to be_empty
    end

    it 'never runs a job that reaches a supplier' do
      supplier_jobs.each do |name|
        expect(described_class.kind_of(name)).to eq(:supplier), name
      end
    end

    it 'drops mail and any job it does not know' do
      expect(described_class.kind_of('ActionMailer::MailDeliveryJob')).to eq(:dropped)
      expect(described_class.kind_of('SomeJobAddedLater')).to eq(:dropped)
    end
  end

  describe 'running jobs' do
    include_context 'demo mode on'
    include_context 'demo jobs inline'

    let(:user) { create(:user, :with_organization) }
    let(:supplier) { create(:supplier, :checkout_enabled) }
    let(:order) do
      create(:order, user: user, supplier: supplier, organization: user.current_organization, status: 'processing')
    end

    it 'places an order as a simulation, never through the placement service' do
      create(:order_item, order: order, quantity: 2, unit_price: 10, line_total: 20)
      expect(Orders::OrderPlacementService).not_to receive(:new)

      PlaceOrderJob.perform_later(order.id)

      order.reload
      expect(order.status).to eq('submitted')
      expect(order.confirmation_number).to eq("DEMO-#{Date.current.strftime('%Y%m%d')}-#{order.id}")
      expect(order.order_items.pluck(:status)).to all(eq('added'))
    end

    it 'runs a database-only job for real' do
      stub_const('DemoSpecLocalJob', Class.new(ApplicationJob) do
        def perform(order_id) = Order.find(order_id).update!(notes: 'ran locally')
      end)
      stub_const("#{described_class}::LOCAL", described_class::LOCAL + ['DemoSpecLocalJob'])

      DemoSpecLocalJob.perform_later(order.id)

      expect(order.reload.notes).to eq('ran locally')
    end

    it 'sends no email queued for later' do
      list = create(:aggregated_list, organization: user.current_organization, created_by: user)
      ActionMailer::Base.deliveries.clear

      MatchingMailer.list_ready(list).deliver_later

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe 'in the background, as on the demo' do
    include_context 'demo mode on'

    let(:user) { create(:user, :with_organization) }
    let(:order) do
      create(:order, user: user, supplier: create(:supplier), organization: user.current_organization,
                     status: 'processing')
    end

    before do
      ActiveJob::Base.queue_adapter = described_class.new
      ActiveRecord::Base.connection_pool.lock_thread = true # the job thread sees this test's rows
    end

    after { ActiveRecord::Base.connection_pool.lock_thread = false }

    it 'finishes a submitted order on its own, after the request' do
      allow(DemoMode::Simulator).to receive(:delay_for).and_return(0)

      PlaceOrderJob.perform_later(order.id)
      expect(order.reload.status).to eq('processing') # not inline: the request returns first

      deadline = 5.seconds.from_now
      sleep 0.1 until order.reload.status != 'processing' || Time.current > deadline
      expect(order.status).to eq('submitted')
    end
  end
end
