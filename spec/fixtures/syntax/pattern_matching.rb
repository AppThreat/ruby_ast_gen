# frozen_string_literal: true
# min_ruby: 3.1.0

Result = Data.define(:status, :payload) if defined?(Data)

case {status: :ok, payload: {user: {id: 1, roles: %i[admin user]}}}
in {status: :ok, payload: {user: {id:, roles: ["admin" | :admin, *rest]}}}
  [id, rest]
in {status: :error, payload: {message:}}
  message
else
  nil
end

value = 42
case [42, 1, 2, 3]
in [^value, *middle, Integer => tail]
  [middle, tail]
end
