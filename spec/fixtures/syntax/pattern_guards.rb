# frozen_string_literal: true
# min_ruby: 3.1.0

values = [1, 2, 3]

case values
in [*, 2, *] if values.size > 2
  :find_with_guard
in [1, *] unless values.empty?
  :head_with_guard
else
  :missing
end
