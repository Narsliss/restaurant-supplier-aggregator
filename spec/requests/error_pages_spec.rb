require "rails_helper"

# Regression (2026-07-30): public/ was empty, so every 404 in production served
# a 0-byte response — chefs saw a blank white screen with no way back. These
# static pages are the last-resort UI for any error Rails can't render in-app,
# so they must exist, be self-contained (no asset pipeline), and offer a way home.
RSpec.describe "Static error pages" do
  %w[404 500 422].each do |code|
    describe "public/#{code}.html" do
      let(:path) { Rails.root.join("public", "#{code}.html") }
      let(:html) { File.read(path) }

      it "exists and is not empty" do
        expect(File.exist?(path)).to be true
        expect(html.bytesize).to be > 500
      end

      it "offers a link back to the app" do
        expect(html).to include('href="/"')
      end

      it "is self-contained — no asset-pipeline or external references" do
        expect(html).not_to match(/stylesheet_link_tag|javascript_include_tag|<%/)
        expect(html).not_to match(%r{(src|href)="https?://})
        expect(html).not_to include("/assets/")
      end

      it "is mobile-friendly" do
        expect(html).to include("viewport")
      end
    end
  end
end
