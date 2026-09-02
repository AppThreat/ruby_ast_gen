# frozen_string_literal: true

require "tempfile"
require "json"

RSpec.describe "JSON shape contracts" do
  def parse_source(source)
    file = Tempfile.new(["json_contract", ".rb"])
    file.write(source)
    file.rewind
    RubyAstGen.parse_file(file.path, File.basename(file.path))
  ensure
    file&.close
    file&.unlink
  end

  def expect_metadata_shape(node)
    expect(node).to include(:type, :meta_data)
    expect(node[:type]).to be_a(String)
    expect(node[:meta_data]).to include(
      :start_line,
      :start_column,
      :end_line,
      :end_column,
      :offset_start,
      :offset_end,
      :code
    )
  end

  # Node hash without meta_data (recursively), for shape snapshots that should not depend on
  # source offsets.
  def strip_metadata(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), result|
        next if key == :meta_data

        result[key] = strip_metadata(nested)
      end
    when Array
      value.map { |item| strip_metadata(item) }
    else
      value
    end
  end

  def flatten_nodes(node)    return [] unless node.is_a?(Hash)

    nested = node.values.flat_map do |value|
      case value
      when Hash
        flatten_nodes(value)
      when Array
        value.flat_map { |item| flatten_nodes(item) }
      else
        []
      end
    end
    [node] + nested
  end

  def param_heavy_source
    <<~RUBY
      def foo(a, b = 1, *rest, c:, d: 2, **opts, &blk)
        [a, b, rest, c, d, opts, blk]
      end

      def bar(**nil)
        zeus
      end

      if /x/i.match?("x")
        puts $1
      end
    RUBY
  end

  it "preserves the method definition contract" do
    ast = parse_source(<<~RUBY)
      def fetch(id, limit: 10, **opts, &block)
        block.call(id, limit, opts)
      end
    RUBY

    expect_metadata_shape(ast)
    expect(ast).to include(type: "def", name: :fetch)
    expect(ast).to include(:arguments, :body)
    expect(ast).not_to have_key(:children)
    expect(ast[:arguments]).to include(:children, type: "args")
  end

  it "preserves the class/module contract" do
    ast = parse_source(<<~RUBY)
      module Api
        class Client < Base
          VERSION = "1.0"
        end
      end
    RUBY

    expect_metadata_shape(ast)
    expect(ast).to include(:name, :body, type: "module")
    expect(ast).not_to have_key(:children)
    expect(ast[:body]).to include(:name, :superclass, :body, type: "class")
  end

  it "preserves the block and call contract" do
    ast = parse_source(<<~RUBY)
      users.map { |user| user.name }
    RUBY

    expect_metadata_shape(ast)
    expect(ast).to include(:call_name, :arguments, :body, type: "block")
    expect(ast).not_to have_key(:children)
    expect(ast[:call_name]).to include(:receiver, :arguments, type: "send", name: :map)
  end

  it "preserves rescue/ensure contract keys" do
    ast = parse_source(<<~RUBY)
      begin
        read
      rescue IOError => error
        fallback(error)
      else
        ok
      ensure
        close
      end
    RUBY

    expect_metadata_shape(ast)
    expect(ast).to include(:body, type: "kwbegin")
    ensure_node = ast[:body].first
    expect(ensure_node).to include(:statement, :body, type: "ensure")
    rescue_node = ensure_node[:statement]
    expect(rescue_node).to include(:statement, :bodies, :else_clause, type: "rescue")
    expect(rescue_node).not_to have_key(:children)
  end

  it "preserves pattern matching contract keys", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.1") do
    ast = parse_source(<<~RUBY)
      case payload
      in {id:, roles: ["admin" | :admin, *rest]}
        id
      else
        nil
      end
    RUBY

    expect_metadata_shape(ast)
    expect(ast).to include(:statement, :bodies, :else_clause, type: "case_match")
    in_pattern = flatten_nodes(ast).find { |node| node[:type] == "in_pattern" }
    expect(in_pattern).to include(:pattern, :guard, :body)
  end

  it "preserves forwarding node contracts", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.2") do
    ast = parse_source(<<~RUBY)
      def wrapper(*, **, &)
        target(*, **, &)
      end
    RUBY

    expect_metadata_shape(ast)
    send_node = ast[:body]
    expect(send_node).to include(:receiver, :arguments, type: "send", name: :target)
    expect(send_node[:arguments].map { |argument| argument[:type] }).to include("forwarded_restarg", "hash", "block_pass")
    forwarded_kwrestarg = flatten_nodes(ast).find { |node| node[:type] == "forwarded_kwrestarg" }
    expect(forwarded_kwrestarg).not_to have_key(:children)
  end

  it "emits null values for anonymous forwarding parameters", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.1") do
    ast = parse_source(<<~RUBY)
      def wrapper(*, **, &)
        target(*, **, &)
      end
    RUBY

    parameter_shapes = ast[:arguments][:children].map { |child| [child[:type], child[:value]] }
    expect(parameter_shapes).to contain_exactly(["restarg", nil], ["kwrestarg", nil], ["blockarg", nil])
  end

  it "preserves the `it` block contract", if: SpecCapabilities::PRISM && SpecCapabilities::GRAMMAR_AT_LEAST.call("3.4") do
    ast = parse_source(<<~RUBY)
      items.select { it.even? }
    RUBY

    itblock = flatten_nodes(ast).find { |node| node[:type] == "itblock" }
    expect(itblock).not_to be_nil
    expect(itblock).to include(:call, :param, :body)
    expect(itblock[:param]).to eq(:it)
    expect(itblock[:call]).to include(type: "send", name: :select)
    expect(itblock[:body]).to include(type: "send", name: :"even?")
    expect(itblock[:body][:receiver]).to include(type: "lvar", value: :it)
  end

  it "preserves the numblock contract" do
    ast = parse_source(<<~RUBY)
      list.map { _1 + _2 }
    RUBY

    numblock = flatten_nodes(ast).find { |node| node[:type] == "numblock" }
    expect(numblock).to include(:call, :param_idx, :body)
    expect(numblock[:param_idx]).to eq(2)
    expect(numblock[:call]).to include(type: "send", name: :map)
    expect(numblock[:body]).to include(type: "send", name: :+)
  end

  it "pins rightward assignment and single-line pattern matching to match_pattern shapes", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.1") do
    ast = parse_source(<<~RUBY)
      {a: 1} => {a:}
      1 in Integer
    RUBY

    rightward = flatten_nodes(ast).find { |node| node[:type] == "match_pattern" }
    expect(rightward).to include(:lhs, :rhs)
    expect(rightward[:lhs][:type]).to eq("hash")
    expect(rightward[:rhs][:type]).to eq("hash_pattern")

    single_line = flatten_nodes(ast).find { |node| node[:type] == "match_pattern_p" }
    expect(single_line).to include(:lhs, :rhs)
  end

  it "preserves find patterns with if/unless guards", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.1") do
    ast = parse_source(<<~RUBY)
      values = [1, 2, 3]
      case values
      in [*, 2, *] if values.size > 2
        :find_with_guard
      in [1, *] unless values.empty?
        :head_with_guard
      else
        :missing
      end
    RUBY

    find_pattern = flatten_nodes(ast).find { |node| node[:type] == "find_pattern" }
    expect(find_pattern).not_to be_nil

    if_guard = flatten_nodes(ast).find { |node| node[:type] == "if_guard" }
    expect(if_guard).to include(:condition)
    expect(if_guard[:condition][:type]).to eq("send")

    unless_guard = flatten_nodes(ast).find { |node| node[:type] == "unless_guard" }
    expect(unless_guard).to include(:condition)
  end

  it "records generator and parser backend metadata at the top level" do
    ast = parse_source("x = 1")

    expect(ast).to include(:generator_version, :parser_backend, :ruby_version)
    expect(ast[:generator_version]).to eq(RubyAstGen::VERSION)
    expect(ast[:ruby_version]).to eq(RUBY_VERSION)
    # The backend actually resolved for this run, not merely a non-empty string: a file that
    # had to be re-parsed by the retry grammar must name the grammar that produced it.
    expect(ast[:parser_backend]).to eq(RubyAstGen.parser_for_current_ruby(log: false).to_s)
  end

  it "keeps parameter and regexp node shapes stable", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.1") do
    ast = parse_source(param_heavy_source)

    # Snapshot of the emitted keys/values per node type (meta_data is asserted separately, and
    # its offsets would make this brittle). This pins the shapes the chen frontend reads, and in
    # particular the shapes produced by the wildcard branches in `add_node_properties`.
    expected = {
      "arg" => { type: "arg", value: :a },
      "optarg" => { type: "optarg", key: :b, value: { type: "int", value: 1 } },
      "restarg" => { type: "restarg", value: :rest },
      "kwarg" => { type: "kwarg", key: :c, value: nil },
      "kwoptarg" => { type: "kwoptarg", key: :d, value: { type: "int", value: 2 } },
      "kwrestarg" => { type: "kwrestarg", value: :opts },
      "blockarg" => { type: "blockarg", value: :blk },
      "kwnilarg" => { type: "kwnilarg", key: nil, value: nil },
      "regopt" => { type: "regopt", value: :i },
      "nth_ref" => { type: "nth_ref", value: 1 }
    }

    expected.each do |type, expected_shape|
      node = flatten_nodes(ast).find { |candidate| candidate[:type] == type }
      expect(node).not_to be_nil, "expected a #{type} node in the parsed AST"
      expect_metadata_shape(node)
      expect(strip_metadata(node)).to eq(expected_shape), "shape drift for #{type}"
    end
  end

  it "matches the golden snapshot of the parameter-heavy fixture", if: SpecCapabilities::GRAMMAR_AT_LEAST.call("3.1") do
    ast = parse_source(param_heavy_source)

    # The full tree in one assertion, with meta_data stripped (offsets shift on any edit to the
    # fixture, which is why an earlier snapshot spec was reverted). Where the per-type spec above
    # spot-checks wildcard branches, this pins every emitted key and value at once — the proof
    # that a refactor of `add_node_properties` (e.g. plan 01 §9's dead-branch cleanup) is
    # output-neutral. Provenance and file-level metadata keys are excluded: they vary per run by
    # design, and magic_comments (plan 02 §2) is file-level data rather than part of the tree
    # this snapshot pins — added deliberately when §2 landed, not silently.
    ast_without_provenance = ast.reject do |key, _|
      %i[file_path rel_file_path generator_version parser_backend ruby_version truncated_nodes
        encoding_scrubbed magic_comments].include?(key)
    end

    expect(strip_metadata(ast_without_provenance)).to eq({
      type: "begin",
      body: [
        {
          type: "def",
          name: :foo,
          arguments: {
            type: "args",
            children: [
              {type: "arg", value: :a},
              {type: "optarg", key: :b, value: {type: "int", value: 1}},
              {type: "restarg", value: :rest},
              {type: "kwarg", key: :c, value: nil},
              {type: "kwoptarg", key: :d, value: {type: "int", value: 2}},
              {type: "kwrestarg", value: :opts},
              {type: "blockarg", value: :blk}
            ]
          },
          body: {
            type: "array",
            children: [
              {type: "lvar", value: :a},
              {type: "lvar", value: :b},
              {type: "lvar", value: :rest},
              {type: "lvar", value: :c},
              {type: "lvar", value: :d},
              {type: "lvar", value: :opts},
              {type: "lvar", value: :blk}
            ]
          }
        },
        {
          type: "def",
          name: :bar,
          arguments: {type: "args", children: [{type: "kwnilarg", key: nil, value: nil}]},
          body: {type: "send", receiver: nil, name: :zeus, arguments: []}
        },
        {
          type: "if",
          condition: {
            type: "send",
            receiver: {
              type: "regexp",
              value: {type: "str", value: "x"},
              opt: {type: "regopt", value: :i}
            },
            name: :"match?",
            arguments: [{type: "str", value: "x"}],
            # Plan 02 §4: explicit call syntax facts on sends. The other sends in this fixture
            # (`zeus`, `puts $1`) are implicit calls and deliberately carry neither key.
            call_operator: ".",
            has_parentheses: true
          },
          then_branch: {
            type: "send",
            receiver: nil,
            name: :puts,
            arguments: [{type: "nth_ref", value: 1}]
          }
        }
      ]
    })
  end

  describe "magic comments (plan 02 §2)" do
    it "captures frozen_string_literal and typed with line numbers" do
      ast = parse_source("# frozen_string_literal: true\n# typed: strict\nx = 1\n")

      expect(ast[:magic_comments]).to eq([
        {name: "frozen_string_literal", value: "true", line: 1},
        {name: "typed", value: "strict", line: 2}
      ])
    end

    it "is always present, empty when the source has none" do
      ast = parse_source("x = 1\n")

      expect(ast).to have_key(:magic_comments)
      expect(ast[:magic_comments]).to eq([])
    end

    it "reports prologue comments only, unquoting double-quoted values" do
      # Ruby honours magic comments only before any code (a frozen_string_literal after code is
      # ignored with a warning, and Sorbet's sigil must precede code as well), so position is part
      # of the rule. Prism's own magic_comments accessor has no position rule, which is why it
      # reports RDoc and commented-out code as magic comments — see MAGIC_COMMENT_PATTERN.
      ast = parse_source(<<~RUBY)
        # coding: "utf-8"
        # typed: strict
        puts 1 # frozen_string_literal: true
        x = 2
        # https://example.com
        # attr_reader: foo
      RUBY

      expect(ast[:magic_comments]).to eq([
        {name: "coding", value: "utf-8", line: 1},
        {name: "typed", value: "strict", line: 2}
      ])
    end

    it "reports a prologue comment that follows a shebang and a banner" do
      ast = parse_source("#!/usr/bin/env ruby\n# Copyright someone\n# frozen_string_literal: true\nx = 1\n")

      expect(ast[:magic_comments]).to eq([{name: "frozen_string_literal", value: "true", line: 3}])
    end

    it "keeps ordinary comments and non-`#` comments out" do
      ast = parse_source("# just a comment\n# typed: strict and also more words\n" \
        "=begin\n# typed: strict\n=end\nx = 1\n")

      expect(ast[:magic_comments]).to eq([])
    end
  end

  describe "send syntax metadata (plan 02 §4)" do
    def call_flags(source)
      ast = parse_source(source)
      [ast[:type], ast[:call_operator], ast[:has_parentheses]]
    end

    it "distinguishes call operators and parenthesization" do
      expect(call_flags("foo.bar baz\n")).to eq(["send", ".", nil])
      expect(call_flags("foo.bar(baz)\n")).to eq(["send", ".", true])
      expect(call_flags("Foo::bar\n")).to eq(["send", "::", nil])
      expect(call_flags("Foo::bar()\n")).to eq(["send", "::", true])
      expect(call_flags("foo&.bar\n")).to eq(["csend", "&.", nil])
      # The plain form stays key-less: no operator, no parentheses.
      expect(call_flags("bar\n")).to eq(["send", nil, nil])
    end

    it "flags percent-notation arrays with their prefix" do
      expect(parse_source("%w[a b]\n")).to include(type: "array", percent_array: "%w")
      expect(parse_source("%i(x y)\n")).to include(type: "array", percent_array: "%i")
      plain = parse_source("[a, b]\n")
      expect(plain).to include(type: "array")
      expect(plain).not_to have_key(:percent_array)
    end

    it "makes the heredoc body reachable through offsets while code stays the marker" do
      source = "x = <<~SQL\n  select 1\nSQL\n"
      ast = parse_source(source)

      str_node = ast[:rhs]
      expect(str_node).to include(type: "str", heredoc: true)
      expect(str_node[:meta_data][:code]).to eq("<<~SQL")
      # The body range is the parser's own: body lines including the final newline, up to the
      # end marker that meta_data's offsets never reach past.
      body = source[str_node[:heredoc_body_start]...str_node[:heredoc_body_end]]
      expect(body).to eq("  select 1\n")
    end

    it "reports the same syntax facts under the prism translation and the parser gem",
      if: SpecCapabilities::PRISM do
      require "parser/current"

      syntax_facts = lambda do |parser_class, source|
        ast, = parser_class.default_parser.parse_with_comments(
          Parser::Source::Buffer.new("(agreement)", source: source))
        flatten_nodes(NodeHandling.ast_to_json(ast, source)).map do |node|
          node.slice(:type, :call_operator, :has_parentheses, :heredoc, :heredoc_body_start,
            :heredoc_body_end, :percent_array)
        end
      end

      ["foo.bar baz\n", "foo.bar(baz)\n", "Foo::bar\n", "Foo::bar()\n", "foo&.bar\n",
        "%w[a b]\n", "x = <<~SQL\n  select 1\nSQL\n"].each do |source|
        prism_facts = syntax_facts.call(RubyAstGen.parser_for_current_ruby(log: false), source)
        gem_facts = syntax_facts.call(::Parser::CurrentRuby, source)
        expect(prism_facts).to eq(gem_facts), "syntax facts diverge for #{source.inspect}"
      end
    end
  end

  describe "Sorbet sig attachment (plan 02 §3)" do
    SORBET_FIXTURE = File.expand_path("fixtures/syntax/sorbet.rb", __dir__)

    def all_defs(ast)
      flatten_nodes(ast).select { |node| %w[def defs].include?(node[:type]) }
    end

    it "marks defs preceded by a sig block and leaves the negative case key-less" do
      ast = parse_source(File.read(SORBET_FIXTURE))

      marked = all_defs(ast).select { |node| node.key?(:has_sig) }
      # format, the abstract validate, ==, Audit#heading and the singleton Reporter.log!
      expect(marked.map { |node| [node[:type], node[:name]] }).to contain_exactly(
        ["def", :format],
        ["def", :validate],
        ["def", :==],
        ["def", :heading],
        ["defs", :log!]
      )
      marked.each do |node|
        expect(node[:has_sig]).to be(true)
        expect_metadata_shape(node)
      end

      # The negative case: a def whose preceding statement is not a sig block carries no
      # has_sig key at all — the fact key is emitted only when it holds.
      plain = all_defs(ast).find { |node| node[:name] == :without_sig }
      expect(plain).not_to be_nil
      expect(plain).not_to have_key(:has_sig)
    end

    it "marks the sig forms real Sorbet code uses" do
      # `.checked(...)`/`.on_failure(...)` wrap the sig block in a send chain, and
      # T::Sig::WithoutRuntime.sig gives it a constant receiver. Both are signatures.
      ast = parse_source(<<~RUBY)
        class Widget
          extend T::Sig

          sig { void }.checked(:never)
          def chained; end

          sig(:final) { returns(String) }
          def final_form; "x"; end

          T::Sig::WithoutRuntime.sig { void }
          def without_runtime; end

          helper.sig { void }
          def not_a_sig; end
        end
      RUBY

      marked = all_defs(ast).select { |node| node.key?(:has_sig) }.map { |node| node[:name] }
      expect(marked).to contain_exactly(:chained, :final_form, :without_runtime)

      # A `sig` block on some other receiver is another DSL, not a signature.
      expect(all_defs(ast).find { |node| node[:name] == :not_a_sig }).not_to have_key(:has_sig)
    end

    it "does not treat a non-sig preceding statement or a sig on a send as an attachment" do
      ast = parse_source(<<~RUBY)
        class Widget
          extend T::Sig

          validate_registration
          def misplaced; end

          sig { void }
          attr_reader :label
        end
      RUBY

      misplaced = flatten_nodes(ast).find { |node| node[:type] == "def" && node[:name] == :misplaced }
      expect(misplaced).not_to have_key(:has_sig)
      # The sig block precedes a send (attr_reader), not a def: nothing is marked anywhere.
      all_defs(ast).each { |node| expect(node).not_to have_key(:has_sig) }
    end
  end

  it "emits blocknilarg as an anonymous parameter once a grammar accepts `def foo(&nil)`" do
    source = "def foo(&nil)\nend\n"
    unless SpecCapabilities.grammar_accepts?(source)
      skip "#{RubyAstGen.parser_for_current_ruby(log: false)} cannot parse `def foo(&nil)` yet (Ruby 4.1 syntax)"
    end

    ast = parse_source(source)
    blocknilarg = flatten_nodes(ast).find { |node| node[:type] == "blocknilarg" }
    expect(blocknilarg).not_to be_nil
    expect(blocknilarg).to include(value: nil)
    expect(blocknilarg).not_to have_key(:children)
  end
end
