# frozen_string_literal: true

require "tempfile"
require "json"

RSpec.describe "non-UTF-8 source handling" do
  # The bytes are written at runtime with binwrite instead of being checked in as corpus
  # fixtures: editors, git autocrlf, and other tooling can silently rewrite non-UTF-8
  # files in a working copy, and the spec must control the bytes exactly.
  def parse_binary_source(bytes)
    file = Tempfile.new(["encoding", ".rb"])
    file.binmode
    file.write(bytes)
    file.flush
    RubyAstGen.parse_file(file.path, File.basename(file.path))
  ensure
    file&.close
    file&.unlink
  end

  def find_first(ast, type)
    found = nil
    stack = [ast]
    while stack.any? && found.nil?
      node = stack.pop
      next unless node.is_a?(Hash)

      found = node if node[:type] == type
      node.each_value do |value|
        case value
        when Hash then stack << value
        when Array then value.each { |item| stack << item if item.is_a?(Hash) }
        end
      end
    end
    found
  end

  it "parses a latin-1 file honouring the coding magic comment" do
    ast = parse_binary_source("# coding: ISO-8859-1\nresult = \"caf\xE9\"\n".b)

    expect(ast).not_to be_nil
    expect { JSON.generate(ast) }.not_to raise_error

    str_node = find_first(ast, "str")
    expect(str_node[:value]).to eq("café")
    expect(str_node[:value].encoding).to eq(Encoding::UTF_8)
    expect(str_node[:meta_data][:code]).to eq("\"café\"")
    # A latin-1 -> UTF-8 conversion is faithful: no replacement characters were needed,
    # so the file must not be marked as scrubbed.
    expect(ast).not_to include(:encoding_scrubbed)
  end

  it "emits scrubbed JSON for files whose bytes are invalid in their declared encoding" do
    ast = parse_binary_source("result = \"bad \xFF\xFE bytes\"\n".b)

    expect(ast).not_to be_nil
    expect { JSON.generate(ast) }.not_to raise_error
    expect(ast[:encoding_scrubbed]).to be(true)

    str_node = find_first(ast, "str")
    expect(str_node[:value]).to eq("bad \uFFFD\uFFFD bytes")
  end

  # A binary-coded file decodes *faithfully* (every byte is valid ASCII-8BIT), so the read path
  # reports no degradation and the string payloads reach JSON.generate still binary-encoded.
  # This is the case that makes the payload walk load-bearing rather than defensive.
  it "emits serializable JSON for a binary-coded source" do
    ast = parse_binary_source("# coding: ASCII-8BIT\nresult = \"caf\xE9\"\n".b)

    expect(ast).not_to be_nil
    expect { JSON.generate(ast) }.not_to raise_error
    expect(ast[:encoding_scrubbed]).to be(true)

    str_node = find_first(ast, "str")
    expect(str_node[:value]).to eq("caf\uFFFD")
    expect(str_node[:value].encoding).to eq(Encoding::UTF_8)
    expect(str_node[:meta_data][:code].encoding).to eq(Encoding::UTF_8)
  end

  it "still emits a degraded AST when the declared encoding name is unusable" do
    ast = parse_binary_source("# coding: nonsense-enc\nresult = 1\n".b)

    expect(ast).not_to be_nil
    expect { JSON.generate(ast) }.not_to raise_error
    expect(ast[:encoding_scrubbed]).to be(true)
    expect(find_first(ast, "int")[:value]).to eq(1)
  end

  it "propagates I/O errors instead of reporting them as encoding problems" do
    expect { RubyAstGen.parse_file("/tmp/ruby_ast_gen_missing_file.rb", "missing.rb") }
      .to raise_error(Errno::ENOENT)
  end

  # The parser normalises CRLF, so snippets must be sliced from the decoded buffer: slicing the
  # raw bytes with normalised offsets truncated every snippet by one char per preceding line
  # (this file used to emit `x = 1 y = "ab` — the closing quote fell off the end).
  it "keeps code snippets aligned with offsets in CRLF sources" do
    ast = parse_binary_source("x = 1\r\ny = \"ab\"\r\n".b)

    expect(ast).not_to be_nil
    # Newlines inside a snippet are collapsed to spaces by NodeHandling.trim_string.
    expect(ast[:meta_data][:code]).to eq("x = 1 y = \"ab\"")
    expect(find_first(ast, "str")[:meta_data][:code]).to eq("\"ab\"")
    expect(ast).not_to include(:encoding_scrubbed)
  end
end
