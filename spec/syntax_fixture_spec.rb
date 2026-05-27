# frozen_string_literal: true

require "json"

RSpec.describe "syntax fixture corpus" do
  FIXTURE_DIR = File.expand_path("fixtures/syntax", __dir__)

  fixture_minimum_ruby_version = lambda do |path|
    File.foreach(path).first(5).filter_map do |line|
      match = line.match(/#\s*min_ruby:\s*([\d.]+)/)
      Gem::Version.new(match[1]) if match
    end.first || Gem::Version.new("3.1.0")
  end

  fixture_supported = lambda do |path|
    Gem::Version.new(RUBY_VERSION) >= fixture_minimum_ruby_version.call(path)
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
