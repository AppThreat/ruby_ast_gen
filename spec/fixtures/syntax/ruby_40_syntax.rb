# frozen_string_literal: true
# min_ruby: 4.0.0

valid = condition_one
  && condition_two

fallback = primary
  || secondary

all_args = [*nil]
callable.call(*nil, **nil)

case [1, 2, 3]
in [*, 2, *]
  :found
else
  :missing
end
