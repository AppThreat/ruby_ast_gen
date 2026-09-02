# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Plan 03 §5 (file discovery) and §7 (thread mechanics).
RSpec.describe "file discovery and worker mechanics" do
  def parse_into(input, **opts)
    Dir.mktmpdir do |out_dir|
      RubyAstGen.parse({input: input, output: out_dir, exclude: "ZZZNOMATCH"}.merge(opts))
      yield out_dir
    end
  end

  describe "the exclusion regex in single-file mode" do
    it "matches the basename, not the absolute path" do
      # `-i /tmp/x/keep.rb -e tmp` used to drop the file: base_dir == file_path made the relative
      # path a no-op, so the regex saw every directory component of the absolute path.
      Dir.mktmpdir("tmp_like") do |dir|
        path = File.join(dir, "keep.rb")
        File.write(path, "x = 1\n")

        Dir.mktmpdir do |out_dir|
          RubyAstGen.parse(input: path, output: out_dir,
            exclude: Regexp.escape(File.basename(dir)))
          expect(File).to exist(File.join(out_dir, "keep.rb.json"))
        end
      end
    end

    it "still applies an exclusion that matches the file itself" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "skip_me.rb")
        File.write(path, "x = 1\n")

        Dir.mktmpdir do |out_dir|
          RubyAstGen.parse(input: path, output: out_dir, exclude: "^skip_me")
          expect(Dir.children(out_dir)).to be_empty
        end
      end
    end

    it "reports rel_file_path as the basename while file_path stays absolute" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "one.rb")
        File.write(path, "x = 1\n")

        parse_into(path) do |out_dir|
          json = JSON.parse(File.read(File.join(out_dir, "one.rb.json")))
          expect(json["rel_file_path"]).to eq("one.rb")
          # Compared through expand_path so the assertion is about the path, not the separator
          # style the platform's tmpdir happens to use.
          expect(File.expand_path(json["file_path"])).to eq(File.expand_path(path))
        end
      end
    end
  end

  describe "dotfiles and dot-directories" do
    it "scans them, but not tool or vendor directories" do
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, ".irbrc"), "x = 1\n")
        {".ci" => "deploy.rb", ".bundle" => "vendored.rb", ".git" => "hook.rb"}.each do |dir, name|
          FileUtils.mkdir_p(File.join(input_dir, dir))
          File.write(File.join(input_dir, dir, name), "x = 1\n")
        end

        parse_into(input_dir) do |out_dir|
          emitted = Dir.glob("#{out_dir}/**/*.json", File::FNM_DOTMATCH).map { |f| File.basename(f) }
          expect(emitted).to include("deploy.rb.json", ".irbrc.json")
          expect(emitted).not_to include("vendored.rb.json", "hook.rb.json")
        end
      end
    end

    it "matches skipped directories by whole path component" do
      # `.gitkeeper/` is not `.git/`.
      Dir.mktmpdir do |input_dir|
        FileUtils.mkdir_p(File.join(input_dir, ".gitkeeper"))
        File.write(File.join(input_dir, ".gitkeeper", "keep.rb"), "x = 1\n")

        parse_into(input_dir) do |out_dir|
          expect(Dir.glob("#{out_dir}/**/*.json", File::FNM_DOTMATCH).map { |f| File.basename(f) }).to eq(["keep.rb.json"])
        end
      end
    end
  end

  describe "--threads" do
    it "parses every file with a single worker" do
      Dir.mktmpdir do |input_dir|
        5.times { |i| File.write(File.join(input_dir, "f#{i}.rb"), "x = #{i}\n") }

        parse_into(input_dir, threads: 1) do |out_dir|
          expect(Dir.glob("#{out_dir}/*.json").size).to eq(5)
        end
      end
    end

    it "warns and uses the default for an unusable value" do
      expect(RubyAstGen::Logger).to receive(:warn).with(/Invalid --threads '0'/)
      expect(RubyAstGen.validated_threads("0")).to eq(RubyAstGen::CLI::DEFAULT_THREADS)
    end
  end

  describe "per-file error containment" do
    # The consumer reads a non-zero exit as "no files were parsed at all", so one unparseable file
    # must never end the run — and the errors a pathological file raises are not all StandardErrors.
    def parse_with_failing_file(error, failing = "bad.rb")
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, failing), "x = 1\n")
        3.times { |i| File.write(File.join(input_dir, "ok#{i}.rb"), "y = #{i}\n") }
        allow(RubyAstGen).to receive(:parse_file).and_wrap_original do |original, path, *args, **kwargs|
          raise error if File.basename(path) == failing

          original.call(path, *args, **kwargs)
        end

        Dir.mktmpdir do |out_dir|
          RubyAstGen.parse(input: input_dir, output: out_dir, exclude: "ZZZNOMATCH", max_threads: 1)
          yield Dir.glob("#{out_dir}/*.json").map { |f| File.basename(f) }.sort
        end
      end
    end

    it "carries on after an error that is not a StandardError" do
      expect(RubyAstGen::Logger).to receive(:info).with(/'bad\.rb' - /)

      parse_with_failing_file(SystemStackError.new) do |emitted|
        expect(emitted).to eq(["ok0.rb.json", "ok1.rb.json", "ok2.rb.json"])
      end
    end

    it "lists the runtime's stack-exhaustion errors" do
      expect(RubyAstGen::PER_FILE_ERRORS).to include(StandardError, SystemStackError)
    end

    if RUBY_PLATFORM == "java"
      it "carries on after JRuby's java.lang.StackOverflowError" do
        # JRuby raises the *Java* Error when the stack runs out inside a Java frame, which is where
        # prism loads nodes: neither a StandardError nor a SystemStackError, so it used to escape
        # every rescue, abandon the queue and exit non-zero — an empty atom for the consumer.
        expect(RubyAstGen::PER_FILE_ERRORS).to include(Java::JavaLang::StackOverflowError)
        expect(RubyAstGen::Logger).to receive(:info).with(/'bad\.rb' - /)

        parse_with_failing_file(Java::JavaLang::StackOverflowError.new) do |emitted|
          expect(emitted).to eq(["ok0.rb.json", "ok1.rb.json", "ok2.rb.json"])
        end
      end
    end

    it "names the error class when the message is empty" do
      # java.lang.StackOverflowError carries no message, so the class name is the only diagnosis.
      stub_const("BlankError", Class.new(StandardError) { def message = "" })

      expect(RubyAstGen.describe_error(BlankError.new)).to eq("BlankError")
      expect(RubyAstGen.describe_error(ArgumentError.new("bad flag"))).to eq("bad flag")
    end
  end

  describe "fetch_member" do
    it "degrades a missing location member to -1 and says so at debug level" do
      expect(RubyAstGen::Logger).to receive(:debug).with(/No location member 'line'/)
      expect(NodeHandling.fetch_member(Object.new, :line)).to eq(-1)
    end

    it "does not swallow errors other than a missing member" do
      exploding = Class.new do
        def line
          raise ArgumentError, "shape changed"
        end
      end.new

      expect { NodeHandling.fetch_member(exploding, :line) }.to raise_error(ArgumentError, "shape changed")
    end
  end
end
