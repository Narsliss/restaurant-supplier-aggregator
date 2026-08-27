require 'rails_helper'

RSpec.describe 'ProductMatches', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:aggregated_list) do
    AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
  end

  before { sign_in owner }

  # Outbound supplier links are ON with the URL formats unverified — every
  # supplier_url is interpolated by the scrapers rather than captured from the
  # site, and US Foods is known to 404. That's deliberate: real clicks decide
  # which suppliers are broken. These specs cover the rendering, NOT whether a
  # URL resolves; nothing here can tell you a link works.
  describe 'GET edit (the matching modal)' do
    let(:linked_supplier) { Supplier.find_by(code: 'sysco') || create(:supplier, name: 'Sysco', code: 'sysco') }
    let(:bare_supplier) { Supplier.find_by(code: 'whatchefswant') || create(:supplier, name: 'What Chefs Want', code: 'whatchefswant') }
    let(:match) { create(:product_match, aggregated_list: aggregated_list) }

    def cell_for(body, supplier)
      Nokogiri::HTML(body).at_css("#match_#{match.id}_supplier_#{supplier.id}")
    end

    def matched_item(supplier, url:)
      sl = create(:supplier_list, supplier: supplier, organization: org, location: location)
      sp = create(:supplier_product, supplier: supplier, supplier_url: url)
      sli = create(:supplier_list_item, supplier_list: sl, supplier_product: sp, name: "#{supplier.short_name} Gouda")
      create(:product_match_item, product_match: match, supplier_list_item: sli)
      sli
    end

    def render_cell(supplier, url:, link_out:)
      sl = create(:supplier_list, supplier: supplier, organization: org, location: location)
      sp = create(:supplier_product, supplier: supplier, supplier_url: url)
      item = create(:supplier_list_item, supplier_list: sl, supplier_product: sp,
                                         name: "#{supplier.short_name} Gouda")
      ApplicationController.renderer.render(
        partial: 'aggregated_lists/supplier_cell_card',
        locals: { product_match: match, supplier: supplier, item: item, pmi: nil,
                  search_url: '/x', supplier_id: supplier.id,
                  is_cheapest: false, is_most_expensive: false,
                  readonly: true, show_image: true, link_out: link_out }
      )
    end

    it 'links a matched cell out to the supplier page' do
      matched_item(linked_supplier, url: 'https://shop.sysco.com/app/product/8462550')

      get edit_aggregated_list_product_match_path(aggregated_list, match)
      expect(response).to have_http_status(:ok)

      links = cell_for(response.body, linked_supplier)
               .css("a[href='https://shop.sysco.com/app/product/8462550']")
      expect(links.size).to eq(2) # image + name
      expect(links.map { |a| a['target'] }.uniq).to eq(['_blank'])
      expect(links.map { |a| a['rel'] }.uniq).to eq(['noopener noreferrer'])
    end

    # US Foods stores /desktop/product/<sku>, which 404s in a browser. The link
    # is rewritten to /desktop/products/ at render time only — the stored URL is
    # left as the scrapers wrote it, because scrape_product navigates the
    # singular path for order price verification and that works.
    it "points the US Foods link at /desktop/products/, not the stored /product/" do
      usf = Supplier.find_by(code: 'usfoods') || create(:supplier, name: 'US Foods', code: 'usfoods')
      matched_item(usf, url: 'https://order.usfoods.com/desktop/product/1268138')

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      href = cell_for(response.body, usf).at_css('a')['href']
      expect(href).to eq('https://order.usfoods.com/desktop/products/1268138')
      expect(response.body).not_to include('/desktop/product/1268138')
    end

    it 'leaves other suppliers\' URLs exactly as stored' do
      matched_item(linked_supplier, url: 'https://shop.sysco.com/app/product/8462550')

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      href = cell_for(response.body, linked_supplier).at_css('a')['href']
      expect(href).to eq('https://shop.sysco.com/app/product/8462550')
    end

    # PPO opens products as modals over the order guide and has no product
    # route: both stored shapes (/item/<uuid> and /products/<sku>) land a chef
    # on their order list. Verified by hand on both, Aug 2026.
    it 'renders PPO as plain text even though it has a URL on file' do
      ppo = Supplier.find_by(code: 'premiereproduceone') ||
            create(:supplier, name: 'Premiere Produce One', code: 'premiereproduceone')
      matched_item(ppo, url: 'https://premierproduceone.pepr.app/item/9f2a7b80-6b16-4e65-a0d3-ce44e62469ad')

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      cell = cell_for(response.body, ppo)
      expect(cell.text).to include('Gouda')
      expect(cell.css('a')).to be_empty
      expect(response.body).not_to include('premierproduceone.pepr.app')
    end

    it 'leaves a supplier with no URL on file as plain text' do
      matched_item(bare_supplier, url: nil)

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      cell = cell_for(response.body, bare_supplier)
      expect(cell.text).to include('WCW Gouda')
      expect(cell.css('a')).to be_empty
    end

    it 'still links image and name when a cell is explicitly asked to' do
      html = render_cell(linked_supplier, url: 'https://shop.sysco.com/app/product/8462550', link_out: true)

      links = Nokogiri::HTML(html).css("a[href='https://shop.sysco.com/app/product/8462550']")
      # Both the image and the name are click targets.
      expect(links.size).to eq(2)
      expect(links.map { |a| a['target'] }.uniq).to eq(['_blank'])
      expect(links.map { |a| a['rel'] }.uniq).to eq(['noopener noreferrer'])
      expect(links.last.text).to include('Gouda')
      expect(links.last.at_css('svg')).to be_present
    end

    it 'renders plain text even with link_out on when there is no URL' do
      html = render_cell(linked_supplier, url: nil, link_out: true)

      expect(html).to include('Gouda')
      expect(Nokogiri::HTML(html).css('a')).to be_empty
    end

    it 'renders plain text when the supplier records no product URL' do
      matched_item(bare_supplier, url: nil)

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      cell = cell_for(response.body, bare_supplier)
      expect(cell.text).to include('WCW Gouda')
      expect(cell.css('a')).to be_empty
    end

    it 'leaves an unmatched cell alone' do
      create(:supplier_list, supplier: bare_supplier, organization: org, location: location)
      matched_item(linked_supplier, url: 'https://shop.sysco.com/app/product/1')

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      cell = cell_for(response.body, bare_supplier)
      expect(cell.text).to include('No match')
      expect(cell.css('a')).to be_empty
    end
  end

  # Regression (Carmin's tester, Aug 2026): highlighting the canonical name and
  # releasing the mouse past the panel edge fired a click on the backdrop and
  # closed the modal mid-edit. The X button and Escape are the only ways out.
  describe 'closing the modal' do
    let(:match) { create(:product_match, aggregated_list: aggregated_list) }

    it 'does not close on a backdrop click' do
      get edit_aggregated_list_product_match_path(aggregated_list, match)

      backdrop = Nokogiri::HTML(response.body).at_css('[data-controller~="match-modal"]')
      expect(backdrop).to be_present
      expect(backdrop['data-action']).to be_nil
    end

    it 'keeps the X button wired to close' do
      get edit_aggregated_list_product_match_path(aggregated_list, match)

      closer = Nokogiri::HTML(response.body).at_css('[data-action="match-modal#close"]')
      expect(closer).to be_present
      expect(closer.name).to eq('button')
    end
  end

  # In the grid a cell click opens the modal, so an outbound anchor there would
  # fight the row handler. The link is deliberately modal-only.
  describe 'GET /aggregated_lists/:id (the grid)' do
    it 'does not link cells out to the supplier' do
      supplier = Supplier.find_by(code: 'sysco') || create(:supplier, name: 'Sysco', code: 'sysco')
      sl = create(:supplier_list, supplier: supplier, organization: org, location: location)
      sp = create(:supplier_product, supplier: supplier, supplier_url: 'https://shop.sysco.com/app/product/8462550')
      sli = create(:supplier_list_item, supplier_list: sl, supplier_product: sp)
      match = create(:product_match, aggregated_list: aggregated_list)
      create(:product_match_item, product_match: match, supplier_list_item: sli)

      get aggregated_list_path(aggregated_list)

      expect(response.body).not_to include('https://shop.sysco.com/app/product/8462550')
    end
  end
  # Chefs sign off on a line once they're happy with the match. Confirmed lines
  # drop out of their category section into a "Confirmed" group at the foot of
  # the page, so what stays above is exactly what still needs attention.
  describe 'confirming a match' do
    let(:supplier) { Supplier.find_by(code: 'sysco') || create(:supplier, name: 'Sysco', code: 'sysco') }
    let(:match) { create(:product_match, aggregated_list: aggregated_list) }

    def matched_line(pm)
      sl = create(:supplier_list, supplier: supplier, organization: org, location: location)
      sli = create(:supplier_list_item, supplier_list: sl)
      create(:product_match_item, product_match: pm, supplier_list_item: sli)
    end

    it 'offers a Confirm match button in the modal once something is matched' do
      matched_line(match)

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      doc = Nokogiri::HTML(response.body)
      form = doc.at_css("form[action='#{confirm_aggregated_list_product_match_path(aggregated_list, match)}']")
      expect(form).to be_present
      expect(form.text).to include('Confirm match')
    end

    it 'offers nothing to confirm on a line with no matched supplier' do
      get edit_aggregated_list_product_match_path(aggregated_list, match)

      expect(response.body).not_to include('Confirm match')
    end

    it 'shows the confirmed state instead of the button once confirmed' do
      matched_line(match)
      match.confirm!

      get edit_aggregated_list_product_match_path(aggregated_list, match)

      expect(response.body).to include('Chef confirmed')
      expect(response.body).not_to include('Confirm match')
    end

    it 'marks the match confirmed and reviewed' do
      matched_line(match)

      post confirm_aggregated_list_product_match_path(aggregated_list, match),
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(match.reload).to be_confirmed
      expect(match.reviewed_at).to be_present
    end

    it 'moves the card to the Confirmed section and closes the modal' do
      matched_line(match)

      post confirm_aggregated_list_product_match_path(aggregated_list, match),
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      body = response.body
      # The badge arrives by redrawing the card's left column...
      expect(body).to include("match_left_#{match.id}")
      expect(body).to include('Chef confirmed')
      # ...and the mover relocates the already-rendered card.
      expect(body).to include('move-to-confirmed')
      expect(body).to include("data-move-to-confirmed-match-id-value=\"product_match_#{match.id}\"")
      expect(body).to include('data-move-to-confirmed-count-value="1"')
      expect(body).to include('match_modal')
    end

    it 'renders confirmed lines in the Confirmed section, not their category' do
      confirmed = create(:product_match, aggregated_list: aggregated_list, canonical_name: 'Signed Off Tomatoes')
      matched_line(confirmed)
      confirmed.confirm!
      pending_line = create(:product_match, aggregated_list: aggregated_list, canonical_name: 'Still Needs A Look')
      matched_line(pending_line)

      get aggregated_list_path(aggregated_list)

      doc = Nokogiri::HTML(response.body)
      shelf = doc.at_css('#confirmed-matches-container')
      expect(shelf).to be_present
      expect(shelf.at_css("##{ActionView::RecordIdentifier.dom_id(confirmed)}")).to be_present
      expect(shelf.at_css("##{ActionView::RecordIdentifier.dom_id(pending_line)}")).to be_nil
      expect(doc.at_css('#confirmed-matches-count').text.strip).to eq('1')
      expect(doc.at_css('#confirmed-matches-header')['class']).not_to include('hidden')
    end

    it 'hides the Confirmed header while nothing is confirmed' do
      matched_line(match)

      get aggregated_list_path(aggregated_list)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('#confirmed-matches-header')['class']).to include('hidden')
      expect(doc.at_css('#confirmed-matches-container')).to be_present
    end
  end
  # BEST reads as "this one is cheaper", which is only true when the suppliers
  # quote in a common unit. When they don't — an each price against an ounce
  # price, a sheet against a bushel — the badge is withheld and the clash is
  # flagged instead.
  describe 'flagging prices that cannot be compared' do
    let(:match) { create(:product_match, aggregated_list: aggregated_list, canonical_name: 'Challah Loaf') }

    def line(supplier_code, name, pack_size, price)
      supplier = Supplier.find_by(code: supplier_code) || create(:supplier, code: supplier_code, name: supplier_code)
      sl = create(:supplier_list, supplier: supplier, organization: org, location: location)
      sp = create(:supplier_product, supplier: supplier, in_stock: true)
      sli = create(:supplier_list_item, supplier_list: sl, supplier_product: sp,
                                        name: name, pack_size: pack_size, price: price)
      create(:product_match_item, product_match: match, supplier_list_item: sli)
      supplier
    end

    context 'when no two suppliers share a unit' do
      before do
        line('usfoods', 'Challah by weight', '6/10 LB', 51.75)   # per-ounce
        line('sysco', 'Challah by the loaf', '24 CT', 79.69)     # per-each
      end

      it 'withholds BEST and flags the clash on the list' do
        get aggregated_list_path(aggregated_list)

        doc = Nokogiri::HTML(response.body)
        card = doc.at_css("##{ActionView::RecordIdentifier.dom_id(match)}")
        expect(card).to be_present
        expect(card.css('span').map { |n| n.text.strip }).not_to include('BEST')
        expect(card.text).to include("Units don't match")
      end

      it 'withholds BEST and says why in the modal' do
        get edit_aggregated_list_product_match_path(aggregated_list, match)

        doc = Nokogiri::HTML(response.body)
        expect(doc.css('span').map { |n| n.text.strip }).not_to include('BEST')
        expect(response.body).to include("Units don't match")
        expect(response.body).to include('No cheapest is shown')
      end
    end

    context 'when some suppliers share a unit and one does not' do
      before do
        line('usfoods', 'Cherry tomato 10lb', '6/10 LB', 29.86)
        line('whatchefswant', 'Cherry tomato 10lb', '6/10 LB', 40.70)
        line('sysco', 'Cherry tomato by count', '24 CT', 57.52)  # the odd unit out
      end

      it 'still names a best among the comparable suppliers' do
        get aggregated_list_path(aggregated_list)

        card = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(match)}")
        expect(card.css('span').map { |n| n.text.strip }).to include('BEST')
        expect(card.text).not_to include("Units don't match")
      end

      it "marks the odd supplier's cell as not compared" do
        get aggregated_list_path(aggregated_list)

        doc = Nokogiri::HTML(response.body)
        sysco = Supplier.find_by(code: 'sysco')
        cell = doc.at_css("#match_#{match.id}_supplier_#{sysco.id}")
        expect(cell.text).to include('Not compared')

        usf = Supplier.find_by(code: 'usfoods')
        expect(doc.at_css("#match_#{match.id}_supplier_#{usf.id}").text).not_to include('Not compared')
      end
    end

    context 'when only one supplier carries the product' do
      before { line('usfoods', 'Challah by weight', '6/10 LB', 51.75) }

      it 'says nothing — there is no comparison to flag' do
        get aggregated_list_path(aggregated_list)

        card = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(match)}")
        expect(card.text).not_to include("Units don't match")
        expect(card.text).not_to include('Not compared')
        expect(card.css('span').map { |n| n.text.strip }).not_to include('BEST')
      end
    end
  end
end
