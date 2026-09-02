# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "tempfile"
require "open3"
require "rbconfig"

# Plan 03 §3: parse failures and error-tolerant warnings emitted as data instead of only
# stdout lines. The side-record naming rule (never `.json` under the output directory) is a
# chen contract: its ingest globs `<out>/**/*.json` and feeds every match to its AST reader.
RSpec.describe "parse diagnostics" do
  def parse_into(input_files, **opts)
    Dir.mktmpdir do |input_dir|
      input_files.each { |name, content| File.write(File.join(input_dir, name), content) }
      Dir.mktmpdir do |out_dir|
        summary = RubyAstGen.parse(input: input_dir, output: out_dir, exclude: "ZZZNOMATCH", **opts)
        yield out_dir, summary
      end
    end
  end

  def diagnostics_lines(out_dir)
    File.readlines(File.join(out_dir, RubyAstGen::DIAGNOSTICS_FILENAME)).map { |line| JSON.parse(line) }
  end

  describe "the per-failure JSONL" do
    it "records every failed file with its diagnosis" do
      parse_into({"good.rb" => "x = 1\n", "broken.rb" => "def foo(\n"}) do |out_dir, summary|
        expect(summary[:files_failed]).to eq(1)

        records = diagnostics_lines(out_dir)
        expect(records.size).to eq(1)
        record = records.first
        expect(record.keys).to eq(["file_path", "rel_file_path", "parse_error"])
        expect(record["rel_file_path"]).to eq("broken.rb")
        expect(File.expand_path(record["file_path"])).to end_with("broken.rb")

        error = record["parse_error"]
        expect(error.keys).to eq(["message", "line", "column", "diagnostic_reason"])
        expect(error["message"]).to be_a(String)
        expect(error["message"]).not_to be_empty
        expect(error["line"]).to be(1)
        expect(error["column"]).to be_a(Integer)
        expect(error["diagnostic_reason"]).to be_a(String)
        expect(error["diagnostic_reason"]).not_to be_empty
      end
    end

    it "is not written when every file parsed, and a stale record from a previous run is removed" do
      parse_into({"good.rb" => "x = 1\n"}) do |out_dir, summary|
        expect(summary[:files_failed]).to eq(0)
        expect(File).not_to exist(File.join(out_dir, RubyAstGen::DIAGNOSTICS_FILENAME))
      end

      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "ok.rb"), "y = 2\n")
        Dir.mktmpdir do |out_dir|
          stale = File.join(out_dir, RubyAstGen::DIAGNOSTICS_FILENAME)
          File.write(stale, "{\"file_path\":\"earlier run\"}\n")

          RubyAstGen.parse(input: input_dir, output: out_dir, exclude: "ZZZNOMATCH")

          # The record must describe this run: no failure here means no record, not last run's.
          expect(File).not_to exist(stale)
        end
      end
    end

    it "adds no new .json file to the output directory" do
      parse_into({"good.rb" => "x = 1\n", "broken.rb" => "def foo(\n"}) do |out_dir, _|
        names = Dir.glob("#{out_dir}/**/*", File::FNM_DOTMATCH)
          .select { |path| File.file?(path) }.map { |path| File.basename(path) }

        expect(names).to contain_exactly("good.rb.json", RubyAstGen::DIAGNOSTICS_FILENAME,
          RubyAstGen::MANIFEST_FILENAME)
        # The only .json file is the AST itself; both side-records are .jsonl.
        expect(names.grep(/\.json\z/)).to eq(["good.rb.json"])
      end
    end
  end

  describe "per-file warning diagnostics" do
    def parse_source(source)
      file = Tempfile.new(["diagnostics", ".rb"])
      file.write(source)
      file.rewind
      RubyAstGen.parse_file(file.path, File.basename(file.path))
    ensure
      file&.close
      file&.unlink
    end

    it "reports error-tolerant warnings as data" do
      # `foo -1` parses fine, and both backends warn about the ambiguous `-`.
      ast = parse_source("foo -1\n")

      expect(ast[:diagnostics]).to include(a_hash_including(
        severity: "warning", line: 1, column: be_between(1, 10).inclusive))
      expect(ast[:diagnostics].first[:message]).to include("-")
      expect(ast).not_to have_key(:diagnostics_truncated)
    end

    it "omits the key entirely when the parse was silent" do
      # No assignment, so even the prism backend's unused-variable check stays silent.
      expect(parse_source("puts 1 + 2\n")).not_to have_key(:diagnostics)
    end

    it "keeps warnings attributed to their own file" do
      parse_into({"clean.rb" => "puts 1 + 2\n", "noisy.rb" => "foo -1\n"}) do |out_dir, _|
        clean = JSON.parse(File.read(File.join(out_dir, "clean.rb.json")))
        noisy = JSON.parse(File.read(File.join(out_dir, "noisy.rb.json")))

        expect(clean).not_to have_key("diagnostics")
        expect(noisy["diagnostics"].first).to include("severity" => "warning")
      end
    end

    it "caps the array and marks the cut" do
      source = Array.new(60) { |index| "call#{index} -1\n" }.join

      ast = parse_source(source)

      expect(ast[:diagnostics].size).to eq(RubyAstGen::DIAGNOSTICS_CAP)
      expect(ast[:diagnostics_truncated]).to be(true)
    end
  end

  describe "stdout and stderr" do
    it "keeps the parser's rendered error off stderr now that it is data" do
      # The parser gem's default_parser renders every diagnostic to stderr; routing them into the
      # diagnostics record instead is what makes them data, and it leaves stderr for genuine
      # process-level noise. The message and its location are on stdout and in the JSONL record.
      exe = File.expand_path("../exe/ruby_ast_gen", __dir__)
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "broken.rb"), "def foo(\n")
        Dir.mktmpdir do |out_dir|
          stdout, stderr, status = Open3.capture3(RbConfig.ruby, exe, "-i", input_dir,
            "-o", out_dir, "-e", "ZZZNOMATCH")

          expect(status).to be_success
          # Asserting on the rendering rather than on an empty stderr: a runtime that prints its
          # own warnings there (some bundler setups do) must not look like a regression.
          expect(stderr).not_to include("def foo(")
          expect(stderr).not_to match(/^\s*\^/)
          expect(stdout).to include("Failed to parse")
          expect(diagnostics_lines(out_dir).first["parse_error"]["line"]).to be(1)
        end
      end
    end
  end

  describe "stdout and exit status" do
    it "logs the failure and exits 0, as before" do
      # The data records are additive: the human-facing line and the consumer-facing exit code
      # (a non-zero exit costs chen every file, plan 04 §10.1) are unchanged.
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "broken.rb"), "def foo(")
        Dir.mktmpdir do |out_dir|
          summary = nil
          expect do
            summary = RubyAstGen.parse(input: input_dir, output: out_dir, exclude: "ZZZNOMATCH")
          end.to output(/\[INFO\] Failed to parse/).to_stdout

          expect(summary[:files_failed]).to eq(1)
        end
      end
    end
  end
end
