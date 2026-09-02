# frozen_string_literal: true
# min_ruby: 3.1

# Operator and literal forms that have no home in the other fixtures (plan 05 §1). Flip-flops and
# `defined?` are here because nothing else in the suite exercised them: both parse to their own
# node types, and both are only reachable in the positions used below.
def scan(lines)
  lines.each do |line|
    # Flip-flops parse only as a condition: `..` is iflipflop, `...` is eflipflop.
    puts line if line =~ /BEGIN/..line =~ /END/
    warn line if line =~ /OPEN/...line =~ /CLOSE/
  end
end

def probes(config)
  # `defined?` is a keyword, not a send.
  return :missing unless defined?(config)
  return :absent unless defined? @cache

  # `not` and `!` are the same send; both spellings kept so neither regresses silently.
  values = [defined?(String), defined?(puts), defined?($stdout)]
  values.reject { |value| not value }
end

def navigation(user)
  # Safe navigation chained with a plain call and an index access.
  user&.profile&.name&.upcase
  user&.roles&.[](0)
end

SYMBOLS = %i[read write execute].freeze
WORDS = %w[alpha beta gamma].freeze
INTERPOLATED_WORDS = %W[tab\there newline\nhere].freeze
INTERPOLATED_SYMBOLS = %I[key\tone key\ttwo].freeze

MATCHERS = [
  /case-insensitive/i,
  /extended  spacing/x,
  /multiline./m,
  /combined/imx
].freeze

RATIO = 3r
NEGATIVE_RATIO = -1/3r
IMAGINARY = 2i
MIXED = 1.5r + 0.5i

RANGES = [1..5, 1...5, (1..), (..5)].freeze
