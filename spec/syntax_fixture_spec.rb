# frozen_string_literal: true

require "json"

RSpec.describe "syntax fixture corpus" do
  FIXTURE_DIR = File.expand_path("fixtures/syntax", __dir__)

  # `# min_ruby: x.y.z` declares the Ruby version whose *grammar* is needed. Since the backend is
  # chosen by capability rather than by RUBY_VERSION, a fixture is exercised whenever the selected
  # grammar is new enough — e.g. Ruby 4.0 syntax is covered on a 3.4 runtime backed by prism.
  fixture_minimum_ruby_version = lambda do |path|
    File.foreach(path).first(5).filter_map do |line|
      match = line.match(/#\s*min_ruby:\s*([\d.]+)/)
      Gem::Version.new(match[1]) if match
    end.first || Gem::Version.new("3.1.0")
  end

  grammar_version = RubyAstGen.parser_grammar_version

  fixture_supported = lambda do |path|
    grammar_version >= fixture_minimum_ruby_version.call(path)
  end

  Dir.glob(File.join(FIXTURE_DIR, "*.rb")).sort.each do |fixture_path|
    fixture_name = File.basename(fixture_path)

    it "parses #{fixture_name} without unhandled node warnings", if: fixture_supported.call(fixture_path) do
      expect(RubyAstGen::Logger).not_to receive(:warn).with(/Unhandled AST node type/)

      ast = RubyAstGen.parse_file(fixture_path, "spec/fixtures/syntax/#{fixture_name}")

      expect(ast).not_to be_nil
      expect(ast).to include(:type, :meta_data, :file_path, :rel_file_path)
      expect { JSON.generate(ast) }.not_to raise_error
    end
  end
end
