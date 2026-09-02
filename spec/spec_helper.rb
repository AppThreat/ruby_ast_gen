# frozen_string_literal: true

require "ruby_ast_gen"

# Capabilities are resolved once, at load time, so they can be used in RSpec `if:` metadata.
# (A symbol in `if:` is always truthy, which silently disables the guard.)
module SpecCapabilities
  PRISM =
    begin
      require "prism"
      require "prism/translation"
      true
    rescue LoadError
      false
    end

  RUBY_AT_LEAST = ->(version) { Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(version) }

  # Whether the grammar in use is new enough for a given syntax level. Prefer this over
  # RUBY_VERSION: the backend is selected by capability, so a 3.1 runtime backed by prism can
  # parse (and must therefore emit correct shapes for) newer syntax.
  GRAMMAR_AT_LEAST = lambda do |version|
    RubyAstGen.parser_grammar_version >= Gem::Version.new(version)
  end

  # True when the grammar in use accepts the snippet, without emitting diagnostics.
  def self.grammar_accepts?(source)
    parser = RubyAstGen.parser_for_current_ruby(log: false).new
    parser.diagnostics.all_errors_are_fatal = true
    parser.diagnostics.ignore_warnings = true
    buffer = Parser::Source::Buffer.new("(capability)", source: source)
    !parser.parse(buffer).nil?
  rescue StandardError
    false
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  # Logger.level is process-global mutable state: a spec that enables debug (directly or through
  # RubyAstGen.parse) would otherwise leak into every later example.
  config.after(:each) { RubyAstGen::Logger.reset_level! }

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
