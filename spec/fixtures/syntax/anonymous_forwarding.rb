# frozen_string_literal: true
# min_ruby: 3.2.0

module Forwarding
  def self.call(...)
    new.call(...)
  end

  def call(*, **, &)
    target(*, **, &)
  end

  private

  def target(*args, **kwargs, &block)
    block&.call(args:, kwargs:)
  end
end
