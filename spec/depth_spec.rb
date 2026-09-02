# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

RSpec.describe "deep nesting truncation" do
  # A nested array literal: every "[" is one AST level, so the source depth is exact.
  def deep_literal(depth, leaves = ["1"])
    "x = #{"[" * depth}#{leaves.join(", ")}#{"]" * depth}"
  end

  def run_parse(input, out_dir, **opts)
    RubyAstGen.parse(input: input, output: out_dir, exclude: "ZZZNOMATCH", **opts)
  end

  def in_input_dir_with(files)
    Dir.mktmpdir do |input_dir|
      files.each { |name, source| File.write(File.join(input_dir, name), "#{source}\n") }
      yield input_dir
    end
  end

  def read_output(out_dir, name)
    JSON.parse(File.read(File.join(out_dir, "#{name}.json")), max_nesting: 2_000)
  end

  def walk_nodes(value, &block)
    case value
    when Hash
      yield value
      value.each_value { |nested| walk_nodes(nested, &block) }
    when Array
      value.each { |item| walk_nodes(item, &block) }
    end
  end

  def truncated_count(json)
    count = 0
    walk_nodes(json) { |node| count += 1 if node["truncated"] }
    count
  end

  # The literal is lvasgn(:x, array(array(...int...))): the outer array hangs off `rhs`
  # (assignments do not keep a children key), deeper arrays off children[0].
  def node_at_depth(json, depth)
    node = json["rhs"]
    (depth - 1).times { node = node["children"][0] }
    node
  end

  it "truncates a ~300-deep literal instead of dropping it" do
    file = Tempfile.new(["deep300", ".rb"])
    begin
      file.write(deep_literal(300))
      file.flush
      Dir.mktmpdir do |out_dir|
        expect { run_parse(file.path, out_dir) }
          .to output(/\[WARN\] .*#{Regexp.quote(File.basename(file.path))}: truncated 1 node\(s\) at max depth 250/)
          .to_stdout

        json = read_output(out_dir, File.basename(file.path))
        expect(json["truncated_nodes"]).to eq(1)
        boundary = node_at_depth(json, 250)
        expect(boundary).to include("type" => "array", "nested" => true, "truncated" => true)
        expect(boundary).not_to have_key("children")
      end
    ensure
      file.close
      file.unlink
    end
  end

  it "leaves a file just under the cap unmarked" do
    file = Tempfile.new(["under240", ".rb"])
    begin
      file.write(deep_literal(240))
      file.flush
      Dir.mktmpdir do |out_dir|
        expect { run_parse(file.path, out_dir) }.not_to output.to_stdout

        json = read_output(out_dir, File.basename(file.path))
        expect(json["truncated_nodes"]).to eq(0)
        expect(truncated_count(json)).to eq(0)
      end
    ensure
      file.close
      file.unlink
    end
  end

  it "serializes a ~60-deep literal that the default JSON nesting limit used to drop" do
    # The regression: JSON.generate's default max_nesting of 100 dies at an AST depth of ~49,
    # so the File.write below used to raise JSON::NestingError and the file was silently
    # skipped (exit 0) even though its AST never came close to the truncation cap.
    file = Tempfile.new(["drop60", ".rb"])
    begin
      file.write(deep_literal(60))
      file.flush
      Dir.mktmpdir do |out_dir|
        expect { run_parse(file.path, out_dir) }.not_to output.to_stdout

        json = read_output(out_dir, File.basename(file.path))
        expect(json).to include("type" => "lvasgn")
        expect(json["truncated_nodes"]).to eq(0)
      end
    ensure
      file.close
      file.unlink
    end
  end

  it "scrubs payloads nested far deeper than any runtime's stack" do
    # Regression test for the CI failure this replaced: the UTF-8 payload walk was recursive, so a
    # file nested near the depth cap raised SystemStackError *after* the AST walk had truncated it
    # correctly, and process_file skipped the file — losing the file the cap exists to preserve.
    # It surfaced only where thread stacks are smaller (Windows, JRuby, TruffleRuby). The depth
    # here is far beyond what recursion could manage on any runtime, so it fails if the walk ever
    # goes back to recursing; it costs milliseconds because iteration has no per-level frame.
    deep = {code: "innermost\xC3".dup.force_encoding("UTF-8")}
    20_000.times { deep = {type: "array", children: [deep]} }

    expect(RubyAstGen.force_utf8_payloads!(deep)).to be(true)

    innermost = deep
    innermost = innermost[:children].first while innermost.key?(:children)
    expect(innermost[:code]).to eq("innermost\uFFFD")
  end

  describe "serialization that outlives the runtime's stack" do
    # JSON.generate recurses per nesting level and how far it gets is a property of the runtime:
    # CRuby's C extension reaches ~100_000 levels, TruffleRuby's Sulong-hosted one dies on a tree
    # at the default cap inside a worker thread. It used to take the whole file with it.
    def fixture_payloads
      Dir.glob(File.expand_path("fixtures/syntax/*.rb", __dir__)).sort.map do |path|
        Dir.mktmpdir do |out_dir|
          run_parse(path, out_dir)
          read_output(out_dir, File.basename(path))
        end
      end
    end

    it "writes byte-identical JSON to the stdlib generator" do
      # The fallback is only worth having if it is indistinguishable from what it replaces, so this
      # compares bytes over the whole fixture corpus plus the escaping cases that actually differ
      # between implementations: quotes, control characters, non-ASCII, and empty containers.
      payloads = fixture_payloads
      expect(payloads).not_to be_empty
      payloads.each do |payload|
        expect(NodeHandling.dump_json(payload)).to eq(JSON.generate(payload, max_nesting: 2_000))
      end

      [{}, [], {"a" => [1, 2, {"b" => nil}]},
       {"code" => "quote\" back\\ tab\t nl\n ctrl\u0001", "sym" => :"weird key"},
       {"n" => -3, "f" => 2.5, "t" => true, "f2" => false, nil => 1},
       {"unicode" => "héllo → 日本語 😀", "nested" => [[[[{"deep" => "x"}]]]]}].each do |payload|
        expect(NodeHandling.dump_json(payload)).to eq(JSON.generate(payload, max_nesting: 2_000))
      end
    end

    it "serializes payloads nested far deeper than any runtime's stack" do
      # 20_000 levels is far past what recursion survives anywhere, so this fails if the writer
      # ever goes back to recursing. It costs milliseconds because iteration has no per-level frame.
      deep = {"code" => "innermost"}
      20_000.times { deep = {"type" => "array", "children" => [deep]} }

      json = NodeHandling.dump_json(deep)

      expect(json).to end_with("#{"]}" * 20_000}")
      expect(json).to include(%("code":"innermost"))
    end

    it "still writes the file when the stdlib generator runs out of stack" do
      # The runtime-dependent path CI only reaches on TruffleRuby: without the fallback the rescue
      # in process_file logs the SystemStackError and the file is never written at all.
      allow(JSON).to receive(:generate).and_raise(SystemStackError)

      # Depth 30 against a cap of 20: enough to truncate, shallow enough that neither the parser nor
      # the iterative writer needs much stack — this runs in a worker thread, which gets far less
      # of it than the main thread does (measured: a JRuby worker at -Xss512k parses 30 levels but
      # not 60).
      in_input_dir_with("deep.rb" => deep_literal(30)) do |input_dir|
        Dir.mktmpdir do |out_dir|
          run_parse(input_dir, out_dir, max_depth: 20)

          json = read_output(out_dir, "deep.rb")
          expect(json["truncated_nodes"]).to be > 0
          expect(json["rel_file_path"]).to eq("deep.rb")
        end
      end
    end
  end

  it "does not leak truncation counts between files in one directory run" do
    # The count travels through the per-file traversal, not module state: 10 worker threads
    # share this process, so a shared counter would misattribute truncations.
    #
    # The cap is lowered instead of the file being made deeper than the default one, so that what
    # is under test is our own bookkeeping rather than how far the *parser* can recurse in a worker
    # thread — which is a runtime property: building a 300-level AST exhausts a worker's stack on
    # JRuby/macOS (inside prism's node loading) though it is fine on the main thread and on Linux.
    # Files the parser cannot handle are logged and skipped, which is a different code path.
    Dir.mktmpdir do |input_dir|
      File.write(File.join(input_dir, "deep.rb"), deep_literal(30))
      File.write(File.join(input_dir, "shallow.rb"), "y = 1")
      Dir.mktmpdir do |out_dir|
        expect { run_parse(input_dir, out_dir, max_depth: 20) }.to output(/\[WARN\] deep\.rb:/).to_stdout

        expect(read_output(out_dir, "deep.rb")["truncated_nodes"]).to be > 0
        expect(read_output(out_dir, "shallow.rb")["truncated_nodes"]).to eq(0)
        expect(truncated_count(read_output(out_dir, "shallow.rb"))).to eq(0)
      end
    end
  end

  it "counts every truncated node but warns at most once per file" do
    # 249 nested arrays with 20 leaves: the innermost array sits just under the cap, so all
    # 20 leaves are truncated by breadth — the per-node warning the old code emitted would
    # have fired 20 times.
    file = Tempfile.new(["wide", ".rb"])
    begin
      file.write(deep_literal(249, (1..20).map(&:to_s)))
      file.flush
      Dir.mktmpdir do |out_dir|
        expect { run_parse(file.path, out_dir) }
          .to output(/\[WARN\] .* truncated 20 node\(s\) at max depth 250 \(first: int\)/).to_stdout

        expect(read_output(out_dir, File.basename(file.path))["truncated_nodes"]).to eq(20)
      end
    ensure
      file.close
      file.unlink
    end
  end

  it "honours the max_depth parse option" do
    file = Tempfile.new(["custom10", ".rb"])
    begin
      file.write(deep_literal(20))
      file.flush
      Dir.mktmpdir do |out_dir|
        run_parse(file.path, out_dir, max_depth: 10)
        json = read_output(out_dir, File.basename(file.path))
        expect(json["truncated_nodes"]).to eq(1)
        expect(node_at_depth(json, 10)).to include("truncated" => true)

        # A more generous cap leaves the same file untouched.
        run_parse(file.path, out_dir, max_depth: 30)
        json = read_output(out_dir, File.basename(file.path))
        expect(json["truncated_nodes"]).to eq(0)
      end
    ensure
      file.close
      file.unlink
    end
  end

  describe "the derived JSON nesting limit" do
    # The load-bearing invariant of this section: json_nesting_limit must exceed what a tree
    # truncated at max_depth can actually reach. If a node handler ever costs three JSON levels
    # per AST level instead of two, JSON.generate would raise again and the file would be dropped
    # with only an [INFO] line — the bug this section fixed. Measured against every nesting shape
    # add_node_properties treats differently (direct child, array slice, put-back children).
    SHAPES = {
      "array" => ->(n) { "x = #{"[" * n}1#{"]" * n}" },
      "hash" => ->(n) { "x = #{"{a: " * n}1#{"}" * n}" },
      "call" => ->(n) { "x = #{"f(" * n}1#{")" * n}" },
      "chain" => ->(n) { "x = a#{".b" * n}" },
      "block" => ->(n) { "x = #{"a.map { " * n}1#{" }" * n}" },
      "if" => ->(n) { "x = #{"(if c then " * n}1#{" end)" * n}" },
      "interpolation" => ->(n) { "x = #{'"#{' * n}1#{'}"' * n}" },
      "boolean" => ->(n) { "x = #{"(1 && " * n}1#{")" * n}" },
      "index" => ->(n) { "x = #{"a[" * n}1#{"]" * n}" },
      "ternary" => ->(n) { "x = #{"(c ? " * n}1#{" : 2)" * n}" }
    }.freeze

    def json_nesting_depth(value)
      case value
      when Hash then value.empty? ? 1 : 1 + value.each_value.map { |v| json_nesting_depth(v) }.max
      when Array then value.empty? ? 1 : 1 + value.map { |v| json_nesting_depth(v) }.max
      else 0
      end
    end

    SHAPES.each do |name, generate|
      it "keeps a truncated #{name} within the limit derived from the cap" do
        cap = 40
        limit = NodeHandling.json_nesting_limit(cap)
        Dir.mktmpdir do |input_dir|
          path = File.join(input_dir, "#{name}.rb")
          File.write(path, "#{generate.call(cap + 20)}\n")
          Dir.mktmpdir do |out_dir|
            run_parse(path, out_dir, max_depth: cap)
            json = read_output(out_dir, "#{name}.rb")
            expect(json["truncated_nodes"]).to be > 0
            expect(json_nesting_depth(json)).to be <= limit
            expect { JSON.generate(json, max_nesting: limit) }.not_to raise_error
          end
        end
      end
    end
  end

  describe "the exclusion regex" do
    it "falls back to the documented default when the option is omitted" do
      # The library API can be called without :exclude; Regexp.new(nil) used to raise TypeError.
      Dir.mktmpdir do |input_dir|
        File.write(File.join(input_dir, "one.rb"), "y = 1")
        Dir.mktmpdir do |out_dir|
          RubyAstGen.parse(input: input_dir, output: out_dir)
          expect(File).to exist(File.join(out_dir, "one.rb.json"))
        end
      end
    end

    it "raises a usage error naming the pattern when it cannot be compiled" do
      expect { RubyAstGen.validated_exclude("[") }
        .to raise_error(ArgumentError, /Invalid --exclude '\['/)
    end
  end

  describe "validated_max_depth" do
    it "defaults silently when no value is given" do
      expect(RubyAstGen.validated_max_depth(nil)).to eq(NodeHandling::MAX_NESTING_DEPTH)
    end

    it "accepts integers and numeric strings" do
      expect(RubyAstGen.validated_max_depth(400)).to eq(400)
      expect(RubyAstGen.validated_max_depth("400")).to eq(400)
    end

    it "warns and falls back to the default for values it cannot use" do
      # Not a usage error: the run continues with the default, like an unknown --log level.
      ["banana", "0", "-5", "3.5"].each do |value|
        expect do
          expect(RubyAstGen.validated_max_depth(value)).to eq(NodeHandling::MAX_NESTING_DEPTH)
        end.to output(/Invalid --max-depth '#{Regexp.quote(value)}'/).to_stdout, "#{value.inspect} should fall back"
      end
    end
  end

  describe "from the command line" do
    def exe_path
      File.expand_path("../exe/ruby_ast_gen", __dir__)
    end

    def run_cli(*args)
      Open3.capture3(RbConfig.ruby, exe_path, *args)
    end

    it "accepts --max-depth" do
      file = Tempfile.new(["cli_depth", ".rb"])
      begin
        file.write(deep_literal(30))
        file.flush
        Dir.mktmpdir do |out_dir|
          _stdout, _stderr, status = run_cli("-i", file.path, "-o", out_dir, "-e", "ZZZNOMATCH", "--max-depth", "20")
          expect(status).to be_success
          json = read_output(out_dir, File.basename(file.path))
          expect(json["truncated_nodes"]).to eq(1)
        end
      ensure
        file.close
        file.unlink
      end
    end

    it "warns and uses the default for an invalid --max-depth" do
      file = Tempfile.new(["cli_depth_bad", ".rb"])
      begin
        file.write(deep_literal(30))
        file.flush
        Dir.mktmpdir do |out_dir|
          stdout, _stderr, status = run_cli("-i", file.path, "-o", out_dir, "-e", "ZZZNOMATCH",
            "--max-depth", "banana")
          expect(status).to be_success
          expect(stdout).to include("Invalid --max-depth 'banana'")
          json = read_output(out_dir, File.basename(file.path))
          expect(json["truncated_nodes"]).to eq(0)
        end
      ensure
        file.close
        file.unlink
      end
    end
  end
end
