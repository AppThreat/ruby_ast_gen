# frozen_string_literal: true
# min_ruby: 3.4.0

items = [1, 2, 3, 4]
selected = items.select { it.even? }
transformed = selected.map do
  it * 10
end

configure(**nil)

class Options
  def initialize(**nil)
  end
end
