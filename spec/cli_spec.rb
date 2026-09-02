# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "CLI argument handling and logging" do
  def exe_path
    File.expand_path("../exe/ruby_ast_gen", __dir__)
  end

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, exe_path, *args)
  end

  def in_input_dir_with(*filenames)
    Dir.mktmpdir do |input_dir|
      filenames.each { |name| File.write(File.join(input_dir, name), "x = 1\n") }
      yield input_dir
    end
  end

  describe "the flag table" do
    # Parsing and --help are both generated from RubyAstGen::CLI::FLAGS, so drift is structurally
    # impossible; these specs pin that the table stays the only dispatcher and the only source of
    # the usage text.
    it "renders every flag in --help and nothing else" do
      help = RubyAstGen::CLI.help_text
      # Usage lines are the only ones whose first token is a flag; description continuations are
      # indented text. Scanning heads rather than whole lines keeps prose (e.g. "same as --log
      # debug") from being mistaken for an entry.
      heads = help.lines.filter_map { |line| line[/\A\s+(-{1,2}[a-z][\w-]*)/, 1] }
      expect(heads).to eq(RubyAstGen::CLI::FLAGS.map { |flag| flag.short || flag.long })
      RubyAstGen::CLI::FLAGS.each { |flag| expect(help).to include(flag.usage) }
    end

    it "accepts exactly the flag names it documents" do
      RubyAstGen::CLI::FLAGS.each do |flag|
        flag.names.each do |name|
          argv = flag.kind == :value ? [name, "value"] : [name]
          expect(RubyAstGen::CLI.parse(argv).warnings).to be_empty, "#{name} was not accepted"
        end
      end

      expect(RubyAstGen::CLI.parse(["--no-such-flag"]).warnings).to include(/Unknown option/)
    end

    it "matches --help against the README usage block" do
      readme = File.read(File.expand_path("../README.md", __dir__))
      # The README shows the same table under a `usage:` line, indented two spaces further.
      body = RubyAstGen::CLI.help_text.split("\n").drop(1).map { |line| "  #{line}" }.join("\n")
      expect(readme).to include(body)
    end
  end

  describe "value handling" do
    it "keeps a value that begins with a hyphen but is not a flag" do
      result = RubyAstGen::CLI.parse(["-e", "-vendor"])
      expect(result.warnings).to be_empty
      expect(result.options[:exclude]).to eq("-vendor")
    end

    it "excludes files with a hyphen-leading regex end to end" do
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "keep.rb"), "x = 1\n")
        File.write(File.join(input_dir, "-skip.rb"), "y = 2\n")
        Dir.mktmpdir do |out_dir|
          _stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "-skip")
          expect(status).to be_success
          expect(Dir.glob(File.join(out_dir, "*.json")).map { |f| File.basename(f) }).to eq(["keep.rb.json"])
        end
      end
    end

    it "warns when an option's value is another flag instead of consuming it" do
      Dir.mktmpdir do |out_dir|
        stdout, _stderr, status = run_cli("-i", "-o", out_dir)
        expect(status).not_to be_success
        expect(stdout).to include("Option -i expects a value")
        expect(stdout).to include("'-i' or '--input' is required.")
      end
    end

    it "warns when an option's value is missing and keeps the default" do
      in_input_dir_with("one.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "--parser-target")
          expect(status).to be_success
          expect(stdout).to include("Option --parser-target expects a value")
          expect(File).to exist(File.join(out_dir, "one.rb.json"))
        end
      end
    end
  end

  describe "logging" do
    it "keeps [DEBUG] lines off stdout without -d" do
      in_input_dir_with("one.rb", "two.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH")
          expect(status).to be_success
          expect(stdout).not_to include("[DEBUG]")
          expect(Dir.glob(File.join(out_dir, "**", "*.json")).length).to eq(2)
        end
      end
    end

    it "shows [DEBUG] lines with -d, resolving the parser once per run" do
      in_input_dir_with("one.rb", "two.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-d", "-e", "ZZZNOMATCH")
          expect(status).to be_success
          expect(stdout).to include("[DEBUG]")
          # The parser selection is memoized, so two files must not produce two "Using parser"
          # lines even though worker threads race to the cache.
          expect(stdout.scan("Using parser:").length).to eq(1)
        end
      end
    end

    it "suppresses [INFO] output at the error log level" do
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "broken.rb"), "def foo(")
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH")
          expect(status).to be_success
          expect(stdout).to include("[INFO] Failed to parse")

          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH", "-l", "error")
          expect(status).to be_success
          expect(stdout).not_to include("[INFO]")
        end
      end
    end

    it "applies --log to the argument warnings themselves" do
      in_input_dir_with("one.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "ZZZNOMATCH", "-l", "error", "--no-such-flag")
          expect(status).to be_success
          expect(stdout).to be_empty
        end
      end
    end

    it "warns and falls back to the default level for an unrecognized --log level" do
      in_input_dir_with("one.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-l", "banana", "-e", "ZZZNOMATCH")
          expect(status).to be_success
          expect(stdout).to include("Unknown log level")
          expect(File).to exist(File.join(out_dir, "one.rb.json"))
        end
      end
    end
  end

  describe "exit status" do
    it "prints the version" do
      stdout, _stderr, status = run_cli("--version")
      expect(status).to be_success
      expect(stdout.strip).to eq(RubyAstGen::VERSION)
    end

    it "prints usage for --help" do
      stdout, _stderr, status = run_cli("--help")
      expect(status).to be_success
      expect(stdout).to include("Usage:")
    end

    it "warns on an unknown flag and still parses the input" do
      in_input_dir_with("one.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", input_dir, "-o", out_dir, "--no-such-flag", "-e", "ZZZNOMATCH")
          expect(status).to be_success
          expect(stdout).to include("Unknown option: --no-such-flag")
          expect(File).to exist(File.join(out_dir, "one.rb.json"))
        end
      end
    end

    it "exits non-zero when -i is missing" do
      stdout, _stderr, status = run_cli
      expect(status).not_to be_success
      expect(stdout).to include("'-i' or '--input' is required.")
    end

    it "reports an unusable exclusion regex without a backtrace" do
      # chen passes a user-configured regex straight through as `-e '<regex>'`, so a malformed one
      # must produce a diagnosis rather than a RegexpError backtrace. Ignoring it is not an
      # option: the run would silently parse everything the caller meant to skip.
      in_input_dir_with("one.rb") do |input_dir|
        Dir.mktmpdir do |out_dir|
          stdout, stderr, status = run_cli("-i", input_dir, "-o", out_dir, "-e", "[")
          expect(status).not_to be_success
          expect(stdout).to include("Invalid --exclude '['")
          expect(stderr).to be_empty
        end
      end
    end

    it "reports an unusable output directory without a backtrace" do
      in_input_dir_with("one.rb") do |input_dir|
        # A regular file standing in for the parent directory: unusable on every platform, unlike
        # `/dev/null/x`, which Windows happily creates as a relative directory.
        blocker = File.join(input_dir, "blocker")
        File.write(blocker, "")
        stdout, stderr, status = run_cli("-i", input_dir, "-o", File.join(blocker, "nope"),
          "-e", "ZZZNOMATCH")
        expect(status).not_to be_success
        expect(stdout).to include("[ERR] Errno::")
        expect(stderr).to be_empty
      end
    end

    it "reports an unusable input path even at the error log level" do
      # This message is the only output of a failed run, so it must not be silenceable: it was
      # logged at :info while still exiting non-zero, which left `-l error` runs failing mutely.
      Dir.mktmpdir do |out_dir|
        stdout, _stderr, status = run_cli("-i", File.join(out_dir, "missing"), "-o", out_dir, "-l", "error")
        expect(status).not_to be_success
        expect(stdout).to include("is neither a file nor a directory")
      end
    end
  end
end
