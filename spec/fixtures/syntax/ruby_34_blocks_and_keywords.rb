# frozen_string_literal: true
# min_ruby: 3.4.0

items = [1, 2, 3, 4]
selected = items.select { it.even? }
transformed = selected.map do
  doubled = it * 10
  doubled.to_s
end
totals = selected.map { it * 2; it + 1 }

configure(**nil)

class Options
  def initialize(**nil)
  end
end
