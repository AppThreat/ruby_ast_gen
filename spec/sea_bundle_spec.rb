# frozen_string_literal: true

require "spec_helper"

# The pressed executables cannot use the repository's gemspec layout (tebako
# presses a Gemfile root), so build/sea.sh and build/sea.ps1 each embed a copy
# of the runtime-only Gemfile: parser, prism, ostruct. Nothing mechanical keeps
# those copies aligned with the Gemfile in the repo root, and a drift ships
# binaries whose parser/prism differ from the gem — silently, because the
# build's smoke tests only assert that *a* prism backend loaded, not which gem
# versions the binary carries. This spec is the alignment check.
RSpec.describe "the SEA build Gemfile" do
  # `gem "name", "constraint"`, with the optional second constraint bundler
  # allows ("~> 3.3", ">= 3.3.1").
  gem_line = /^\s*gem\s+"[^"]+",\s*"[^"]+"(?:\s*,\s*"[^"]+")?/
  root = File.expand_path("..", __dir__)

  # define_method, not def: the pattern and root above are block locals, which
  # a def body cannot see.
  define_method(:gem_lines) do |source|
    source.scan(gem_line).map(&:strip).sort
  end

  # The two heredoc/here-string copies the build scripts embed.
  let(:sea_sh_gem_lines) { gem_lines(File.read(File.join(root, "build", "sea.sh"))) }
  let(:sea_ps1_gem_lines) { gem_lines(File.read(File.join(root, "build", "sea.ps1"))) }
  # The repository Gemfile with its development group cut out: what remains is
  # the runtime set the binaries have to carry, so a new runtime gem added
  # there fails this spec until it is vendored into both build scripts, while
  # a new development gem is correctly ignored.
  let(:repo_runtime_gem_lines) do
    gemfile = File.read(File.join(root, "Gemfile"))
    expect(gemfile).to match(/^group :development do$/), "the Gemfile's development group is gone"
    gem_lines(gemfile.gsub(/^group :development do$.*?^end$/m, ""))
  end

  it "is identical in both build scripts" do
    expect(sea_ps1_gem_lines).to eq(sea_sh_gem_lines)
  end

  it "is exactly the repository Gemfile's runtime set, verbatim" do
    # Set equality in both directions: a runtime gem added to the Gemfile but
    # not vendored ships a binary missing a dependency, and a gem vendored but
    # not declared ships one the gem itself does not use. Verbatim string
    # comparison, deliberately: "~> 1.9" in the build copy and "~> 1.10" in the
    # Gemfile would both satisfy a version-interval check, but only one of them
    # is what the gem actually declares.
    expect(sea_sh_gem_lines).to eq(repo_runtime_gem_lines)
  end

  it "carries the parser and prism backends the AST output depends on" do
    # A floor under the set comparison above: it would still pass if both sides
    # lost the same gem, and a binary without these two cannot parse anything.
    expect(sea_sh_gem_lines).to include(
      %q{gem "parser", "~> 3.3.12.0"},
      %q{gem "prism", "~> 1.9"}
    )
  end
end
