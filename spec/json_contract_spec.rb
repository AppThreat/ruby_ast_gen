# frozen_string_literal: true

require "tempfile"

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

  def flatten_nodes(node)
    return [] unless node.is_a?(Hash)

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

  it "preserves pattern matching contract keys", if: (Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1.0")) do
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

  it "preserves forwarding node contracts", if: (Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2.0")) do
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
end
