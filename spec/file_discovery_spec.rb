# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "Ruby file discovery" do
  # Keep in sync with RUBY_FILE_BASENAMES / RUBY_FILE_EXTENSIONS in lib/ruby_ast_gen.rb.
  expected_basenames = %w[
    Rakefile Gemfile Capfile Thorfile Guardfile Berksfile Podfile Vagrantfile
    Steepfile Puppetfile Dangerfile Fastfile Appfile Pluginfile Matchfile Scanfile
    Snapfile Gymfile Deliverfile Brewfile
  ]

  expected_extensions = %w[.rb .gemspec .rake .ru .rbi .thor .jbuilder .axlsx .rabl]

  it "recognizes well-known Ruby DSL basenames exactly, in any directory" do
    expected_basenames.each do |name|
      expect(RubyAstGen.ruby_file?(name)).to be(true), "expected #{name} to be recognized"
      expect(RubyAstGen.ruby_file?("engines/blog/#{name}")).to be(true), "expected nested #{name} to be recognized"
      expect(RubyAstGen.ruby_file?(name.downcase)).to be(true), "expected #{name.downcase} to be recognized"
    end
  end

  it "does not extend basename matches to suffixes" do
    %w[Gemfile.lock Rakefile.md Capfile.txt Brewfile~ Gemfile.bak Rakefile.orig].each do |path|
      expect(RubyAstGen.ruby_file?(path)).to be(false), "expected #{path} to be skipped"
    end
  end

  it "recognizes Ruby extensions case-insensitively" do
    expected_extensions.each do |ext|
      expect(RubyAstGen.ruby_file?("app/models#{ext}")).to be(true), "expected #{ext} to be recognized"
      expect(RubyAstGen.ruby_file?("app/models#{ext.upcase}")).to be(true), "expected #{ext.upcase} to be recognized"
    end
  end

  it "rejects non-Ruby files" do
    %w[README.md Gemfile.lock package.json Makefile bin/setup data/notes.txt].each do |path|
      expect(RubyAstGen.ruby_file?(path)).to be(false), "expected #{path} to be skipped"
    end
  end

  it "discovers exactly the Ruby files in a project layout" do
    layout_root = File.expand_path("fixtures/project_layout", __dir__)

    Dir.mktmpdir do |out_dir|
      RubyAstGen.parse(input: layout_root, output: out_dir, exclude: "ZZZNOMATCH", debug: false)

      emitted = Dir.glob(File.join(out_dir, "**", "*.json")).sort
        .map { |path| path.delete_prefix("#{out_dir}/") }

      expect(emitted).to eq([
        "Gemfile.json",
        "Rakefile.json",
        "config.ru.json",
        "lib/task.rake.json",
        "sig/model.rbi.json"
      ])
    end
  end
end
