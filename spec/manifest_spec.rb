# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "open3"
require "rbconfig"

# Plan 03 §4: a per-run manifest inside the output directory, plus the opt-in --fail-on-error.
# The default exit code stays 0 whatever a run hit — chen reads a non-zero exit as "no files
# parsed at all" and produces an empty atom (plan 04 §10.1).
RSpec.describe "the run manifest" do
  MANIFEST_KEYS = %w[
    input output ruby_version parser_backend generator_version generated_at
    files_parsed files_failed files_skipped_nonruby files_excluded truncated_files
    threads max_depth parser_target
  ].freeze

  def parse_into(input_files, **opts)
    Dir.mktmpdir do |input_dir|
      input_files.each { |name, content| File.write(File.join(input_dir, name), content) }
      Dir.mktmpdir do |out_dir|
        summary = RubyAstGen.parse(input: input_dir, output: out_dir, exclude: "ZZZNOMATCH", **opts)
        yield out_dir, summary
      end
    end
  end

  def read_manifest(out_dir)
    path = File.join(out_dir, RubyAstGen::MANIFEST_FILENAME)
    lines = File.readlines(path)
    expect(lines.size).to eq(1)
    JSON.parse(lines.first)
  end

  it "is a single JSON line with exactly the documented keys" do
    parse_into({"a.rb" => "a = 1\n", "b.rb" => "b = 2\n"}) do |out_dir, summary|
      manifest = read_manifest(out_dir)

      expect(manifest.keys).to contain_exactly(*MANIFEST_KEYS)
      expect(manifest["generator_version"]).to eq(RubyAstGen::VERSION)
      expect(manifest["ruby_version"]).to eq(RUBY_VERSION)
      expect(manifest["parser_backend"]).to eq(RubyAstGen.parser_for_current_ruby(log: false).to_s)
      expect(manifest["files_parsed"]).to eq(2)
      expect(manifest["files_failed"]).to eq(0)
      expect(manifest["files_skipped_nonruby"]).to eq(0)
      expect(manifest["files_excluded"]).to eq(0)
      expect(manifest["truncated_files"]).to eq(0)
      expect(manifest["threads"]).to eq(RubyAstGen::CLI::DEFAULT_THREADS)
      expect(manifest["max_depth"]).to eq(NodeHandling::MAX_NESTING_DEPTH)
      expect(manifest["parser_target"]).to be_nil
      expect(manifest["generated_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(manifest["input"]).to be_a(String)
      expect(manifest["output"]).to be_a(String)

      # .parse returns the manifest it wrote, which is how the CLI implements --fail-on-error.
      expect(summary.transform_keys(&:to_s)).to eq(manifest)
    end
  end

  it "counts every outcome exactly, one worker at a time" do
    files = {
      "a.rb" => "a = 1\n", "b.rb" => "b = 2\n", "c.rb" => "c = 3\n",
      "broken1.rb" => "def foo(\n", "broken2.rb" => "class Bar\n",
      "notes.txt" => "not ruby\n", "skip_me.rb" => "d = 4\n"
    }

    parse_into(files, threads: 1, exclude: "^skip_me") do |_out_dir, summary|
      expect(summary[:files_parsed]).to eq(3)
      expect(summary[:files_failed]).to eq(2)
      expect(summary[:files_skipped_nonruby]).to eq(1)
      expect(summary[:files_excluded]).to eq(1)
    end
  end

  it "counts exactly under the default thread pool, where workers race for files" do
    files = {}
    35.times { |index| files["ok#{index}.rb"] = "x#{index} = #{index}\n" }
    5.times { |index| files["bad#{index}.rb"] = "def broken#{index}(\n" }

    parse_into(files) do |_out_dir, summary|
      expect(summary[:files_parsed]).to eq(35)
      expect(summary[:files_failed]).to eq(5)
    end
  end

  it "reports a run that parsed nothing instead of leaving the consumer to guess" do
    parse_into({"notes.txt" => "not ruby\n"}) do |out_dir, summary|
      expect(summary[:files_parsed]).to eq(0)
      expect(read_manifest(out_dir)["files_parsed"]).to eq(0)
    end
  end

  it "counts files whose output was truncated" do
    # 30 nested arrays against a cap of 20: one truncation point, still a parsed file. The depth
    # is kept low on purpose — worker-thread stacks on some runtimes (JRuby with a small -Xss)
    # cannot parse far deeper than this, and the spec is about the count, not the ceiling.
    deep = "x = #{Array.new(30) { "[" }.join}1#{Array.new(30) { "]" }.join}\n"
    shallow = "y = #{Array.new(10) { "[" }.join}1#{Array.new(10) { "]" }.join}\n"

    parse_into({"deep.rb" => deep, "shallow.rb" => shallow}, max_depth: 20) do |_out_dir, summary|
      expect(summary[:files_parsed]).to eq(2)
      expect(summary[:truncated_files]).to eq(1)
    end
  end

  it "records the requested parser target and depth" do
    parse_into({"a.rb" => "a = 1\n"}, parser_target: "3.4", max_depth: 123) do |out_dir, _|
      manifest = read_manifest(out_dir)
      expect(manifest["parser_target"]).to eq("3.4")
      expect(manifest["max_depth"]).to eq(123)
    end
  end

  it "names the backend the run actually used, not the newest one available" do
    # --parser-target 2.7 resolves to the parser gem grammar, which no prism translation covers.
    # Reporting the newest backend here would describe a run that never happened, and the
    # manifest exists to describe the run.
    parse_into({"a.rb" => "a = 1\n"}, parser_target: "2.7") do |out_dir, _|
      manifest = read_manifest(out_dir)
      emitted = JSON.parse(File.read(File.join(out_dir, "a.rb.json")))

      expect(manifest["parser_backend"]).to eq("Parser::Ruby27")
      expect(manifest["parser_backend"]).to eq(emitted["parser_backend"])
    end
  end

  describe "--fail-on-error" do
    def run_cli(*args)
      exe = File.expand_path("../exe/ruby_ast_gen", __dir__)
      Open3.capture3(RbConfig.ruby, exe, *args)
    end

    it "is off by default: a failing file still exits 0" do
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "broken.rb"), "def foo(")
        Dir.mktmpdir do |out_dir|
          _stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH")
          expect(status).to be_success
          expect(File).to exist(File.join(out_dir, RubyAstGen::DIAGNOSTICS_FILENAME))
        end
      end
    end

    it "exits non-zero with the flag when a file failed" do
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "broken.rb"), "def foo(")
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH",
            "--fail-on-error")
          expect(status).not_to be_success
          expect(stdout).to include("1 file(s) failed to parse")
        end
      end
    end

    it "exits 0 with the flag when every file parsed" do
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "ok.rb"), "x = 1\n")
        Dir.mktmpdir do |out_dir|
          _stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH",
            "--fail-on-error")
          expect(status).to be_success
        end
      end
    end

    it "counts a failing single-file input" do
      Dir.mktmpdir do |input_dir|
        broken = File.join(input_dir, "broken.rb")
        File.write(broken, "def foo(")
        Dir.mktmpdir do |out_dir|
          _stdout, _stderr, status = run_cli("-i", broken, "-o", out_dir, "--fail-on-error")
          expect(status).not_to be_success
          expect(File).to exist(File.join(out_dir, RubyAstGen::DIAGNOSTICS_FILENAME))
        end
      end
    end
  end
end
