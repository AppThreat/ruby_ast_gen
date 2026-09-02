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

  it "reports gem versions from the loaded libraries when RubyGems has no specs" do
    # A `--standalone` bundle (how atom-parsetools ships this tool) loads the gems by load path
    # rather than activating them, leaving `Gem.loaded_specs` empty. The report must still name the
    # versions it is parsing with; blinding RubyGems is what that bundle looks like from here.
    RubyAstGen.parser_info # load the parser libraries before Gem.loaded_specs is stubbed away
    allow(Gem).to receive(:loaded_specs).and_return({})

    info = RubyAstGen.parser_info

    expect(Object.const_defined?("Parser::VERSION")).to be(true)
    expect(info[:parser_gem_version]).to eq(Parser::VERSION)
    expect(RubyAstGen.parser_info_text).to include("Parser gem: #{Parser::VERSION}")
    if Object.const_defined?("Prism::VERSION")
      expect(info[:prism_gem_version]).to eq(Prism::VERSION)
      expect(RubyAstGen.parser_info_text).not_to include("unavailable")
    end
  end

  it "reports a library that is not loaded at all as unavailable" do
    expect(RubyAstGen.library_version("no_such_gem", "NoSuchGem::VERSION")).to be_nil
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
