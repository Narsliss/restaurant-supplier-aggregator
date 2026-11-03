require "rails_helper"

RSpec.describe PlainTextNameValidator do
  let(:model) do
    Class.new do
      include ActiveModel::Model
      attr_accessor :name
      validates :name, plain_text_name: true
      def self.name = "NameHolder"
    end
  end

  def valid?(value) = model.new(name: value).valid?

  REAL_NAMES = [
    "O'Brien", "José Álvarez", "Smith-Jones", "Mary Ann", "Đặng",
    "Las Noches", "Bar & Grill", "St. Elmo's", "Eat.Drink", "Café 21",
    "Joe's Pizza (Downtown)", "Restaurant #2", "50/50 Kitchen", "Noche @ Main",
    "Etxe Cincinnati", "Doro", ""
  ].freeze

  REAL_NAMES.each do |name|
    it "allows #{name.inspect}" do
      expect(valid?(name)).to be(true)
    end
  end

  [
    '* * * <a href="https://myxa.cc/">SCAM SERVICE 24/7</a> * * *',
    "<script>alert(1)</script>",
    "Visit https://spam.example",
    "http://spam.example",
    "go to WWW.spam.example",
    "a > b"
  ].each do |name|
    it "rejects #{name.inspect}" do
      record = model.new(name: name)
      expect(record).not_to be_valid
      expect(record.errors[:name]).to include("can't contain links or the < > characters")
    end
  end

  it "does not match bare domains (deliberately, too many real names have dots)" do
    expect(valid?("myxa.cc")).to be(true)
  end
end
