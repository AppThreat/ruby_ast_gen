# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "parser capability reporting" do
  it "exposes parser capability metadata" do
    info = RubyAstGen.parser_info

    expect(info).to include(
      ruby_engine: a_kind_of(String),
      ruby_version: RUBY_VERSION,
      ruby_platform: RUBY_PLATFORM,
      parser_backend: a_kind_of(String),
      prism_translation_parsers: a_kind_of(Array)
    )
    expect(info[:parser_backend]).not_to be_empty
  end

  it "prints parser capability metadata from the CLI without requiring input" do
    exe = File.expand_path("../exe/ruby_ast_gen", __dir__)
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, exe, "--parser-info")

    expect(status).to be_success
    expect(stdout).to include("Ruby version: #{RUBY_VERSION}")
    expect(stdout).to include("Parser backend:")
    expect(stdout).to include("Parser gem:")
    expect(stdout).to include("Prism translation parsers:")
  end
end
