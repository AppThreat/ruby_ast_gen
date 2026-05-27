# frozen_string_literal: true
# min_ruby: 3.1.0

RSpec.describe "Orders API" do
  let(:headers) { {"Content-Type" => "application/json"} }
  let(:payload) do
    {
      order: {
        id: 123,
        line_items: [{sku: "ABC", quantity: 2}]
      }
    }
  end

  subject(:request!) { post "/orders", params: payload.to_json, headers: headers }

  it "creates an order" do
    expect { request! }.to change(Order, :count).by(1)
  end
end
