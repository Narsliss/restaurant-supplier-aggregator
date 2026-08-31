require 'rails_helper'

# The method behind the savings figures should be readable in the product, so
# nobody has to reconstruct it from the number or explain it to a chef by hand.
RSpec.describe 'reports/_savings_explainer', type: :view do
  it 'states both halves and that they sum to the spread' do
    render partial: 'reports/savings_explainer'

    expect(rendered).to include('what you beat the most expensive supplier by')
    expect(rendered).to include("what you'd have saved buying from the cheapest")
    expect(rendered).to include('add up to the')
  end

  it 'explains that prices are converted to one unit before comparing' do
    render partial: 'reports/savings_explainer'

    expect(rendered).to match(/case at \$2\.50\/lb is \$100/)
  end

  it 'says an uncomparable line is left out rather than counted as zero' do
    render partial: 'reports/savings_explainer'

    expect(rendered).to include('not counted')
    expect(rendered).to match(/smaller number we can stand behind/)
  end

  it 'shows coverage when the counts are supplied' do
    render partial: 'reports/savings_explainer',
           locals: { compared_lines: 351, total_lines: 477,
                     compared_spend: 27_722.79, total_spend: 41_068.86 }

    expect(rendered).to include('What this covers')
    expect(rendered).to include('351')
    expect(rendered).to include('477')
    expect(rendered).to include('$27,722.79')
  end

  it 'omits the coverage block when nothing was compared' do
    render partial: 'reports/savings_explainer',
           locals: { compared_lines: 0, total_lines: 0,
                     compared_spend: 0, total_spend: 0 }

    expect(rendered).not_to include('What this covers')
  end
end
