# frozen_string_literal: true

module NodeHandling
  # AST levels to emit before truncating. Each emitted level costs at most two JSON nesting
  # levels (the node object and the array/hash holding its children), so the JSON nesting limit
  # must always be derived from this cap via .json_nesting_limit — JSON.generate's default of
  # 100 dies at an AST depth of ~49, which used to make serialization fail and cost the whole
  # file for inputs this cap never saw.
  MAX_NESTING_DEPTH = 250

  # The JSON.generate max_nesting that always accepts a tree truncated at +max_depth+ AST
  # levels (+2 for the deepest node's own meta_data, plus headroom).
  def self.json_nesting_limit(max_depth = MAX_NESTING_DEPTH)
    max_depth * 2 + 16
  end

  # A pre-rendered piece of output. Payload values are never Fragments, which is how the writer
  # below tells punctuation it queued from data it still has to render.
  Fragment = Struct.new(:text)

  OPEN_OBJECT = Fragment.new("{").freeze
  CLOSE_OBJECT = Fragment.new("}").freeze
  CLOSE_ARRAY = Fragment.new("]").freeze
  COMMA = Fragment.new(",").freeze

  # Serializes the payload without recursion.
  #
  # `JSON.generate` recurses once per nesting level, and how deep that can go is a property of the
  # runtime, not of the JSON: on CRuby the C extension manages ~100_000 levels, but on TruffleRuby
  # it runs through Sulong and a tree truncated at the default cap of 250 AST levels exhausts a
  # worker thread's stack. The file was then logged and skipped — the outcome the depth cap exists
  # to prevent, and one that made the output depend on the interpreter. Iterating has no depth
  # limit, so a file that parses is emitted on every runtime. Scalars still go through the stdlib,
  # since that is where the escaping rules live.
  def self.dump_json(value)
    out = +""
    stack = [value]

    until stack.empty?
      item = stack.pop
      case item
      when Fragment
        out << item.text
      when Hash
        out << "{"
        queued = []
        item.each_with_index do |(key, nested), index|
          queued << Fragment.new("#{index.zero? ? "" : ","}#{key.to_s.to_json}:")
          queued << nested
        end
        queued << CLOSE_OBJECT
        stack.concat(queued.reverse!)
      when Array
        out << "["
        queued = []
        item.each_with_index do |nested, index|
          queued << COMMA unless index.zero?
          queued << nested
        end
        queued << CLOSE_ARRAY
        stack.concat(queued.reverse!)
      else
        out << json_scalar(item)
      end
    end

    out
  end

  # Scalars are rendered exactly as JSON.generate would, including UTF-8 passed through unescaped.
  def self.json_scalar(value)
    case value
    when nil then "null"
    when true then "true"
    when false then "false"
    when Integer then value.to_s
    when Symbol then value.to_s.to_json
    else value.to_json
    end
  end

  SINGLETONS = %i[nil true false].freeze
  LITERALS = %i[int float rational complex str sym __FILE__ __LINE__ __ENCODING__].freeze
  CALLS = %i[send csend].freeze
  DYNAMIC_LITERALS = %i[dsym dstr].freeze
  CONTROL_KW = %i[break next].freeze
  ARGUMENTS = %i[arg restarg blockarg kwrestarg shadowarg itarg blocknilarg].freeze
  KW_ARGUMENTS = %i[kwarg kwnilarg kwoptarg].freeze
  REFS = %i[nth_ref back_ref].freeze
  FORWARD_ARGUMENTS = %i[forward_args forwarded_args forward_arg forwarded_restarg
    forwarded_kwrestarg].freeze
  ASSIGNMENTS = %i[or_asgn and_asgn lvasgn ivasgn gvasgn cvasgn match_with_lvasgn match_write].freeze
  BIN_OP = %i[and or in_match match_pattern match_pattern_p].freeze
  ACCESS = %i[self ident lvar cvar gvar ivar splat kwsplat block_pass
    match_var].freeze
  QUAL_ACCESS = [:casgn].freeze
  COLLECTIONS = %i[args array hash mlhs hash_pattern array_pattern
    array_pattern_with_tail find_pattern kwargs undef procarg0].freeze
  SPECIAL_CMD = %i[yield super defined? xstr not].freeze
  RANGE_OP = %i[erange irange eflipflop iflipflop].freeze

  # A missing location member is expected for synthesized nodes, so it degrades to -1. The rescue
  # is narrow on purpose (plan 03 §9): a bare `rescue` also hid genuine shape changes in the
  # parser's location classes behind a plausible-looking offset.
  def self.fetch_member(loc, method)
    loc.public_send(method)
  rescue NoMethodError => e
    RubyAstGen::Logger.debug "No location member '#{method}' on #{loc.class}: #{e.message}"
    -1
  end

  # Syntax facts the parser's locations already know, attached at the node level (plan 02 §4).
  # Keys are emitted only when the fact holds, so the plain form stays key-less — the same
  # convention as optional per-type keys like superclass. All values were verified identical on
  # the prism translation and the parser gem.
  #
  #   send/csend: call_operator ("." | "::" | "&.") when the call carries an explicit operator,
  #     and has_parentheses when it was written with parentheses. A block node's begin/end are
  #     `do`/`{` and `end`/`}`, so blocks deliberately get no has_parentheses key.
  #   heredoc strings: heredoc: true plus the character offsets of the body. meta_data covers
  #     only the `<<~SQL` marker, so these offsets are the only way to reach the body text
  #     without re-lexing the source.
  #   array: percent_array ("%w" | "%i" | "%W" | "%I") when the literal used percent notation,
  #     regardless of the delimiter that follows it.
  def self.syntax_metadata(node_type, loc)
    metadata = {}
    return metadata unless loc

    if CALLS.include?(node_type)
      dot = loc.respond_to?(:dot) ? loc.dot : nil
      metadata[:call_operator] = dot.source if dot
      metadata[:has_parentheses] = true if loc.begin && loc.end
    elsif loc.is_a?(::Parser::Source::Map::Heredoc)
      metadata[:heredoc] = true
      metadata[:heredoc_body_start] = loc.heredoc_body.begin_pos
      metadata[:heredoc_body_end] = loc.heredoc_body.end_pos
    elsif node_type == :array && loc.begin
      prefix = loc.begin.source[/\A%[wiWI]/]
      metadata[:percent_array] = prefix if prefix
    end
    metadata
  end

  # +state+ accumulates the truncation count for one file. It is threaded through the recursion
  # (not kept in module state) because 10 worker threads share this module: a shared counter
  # would race and attribute one file's truncations to another. The caller reads the count to
  # emit one warning per file and the top-level truncated_nodes key.
  def self.ast_to_json(node, code, current_depth: 0, file_path: nil, max_depth: MAX_NESTING_DEPTH,
    state: {truncated: 0, first_type: nil})
    return unless node.is_a?(Parser::AST::Node)

    loc = node.location
    meta_data = {
      start_line: fetch_member(loc, :line),
      start_column: fetch_member(loc, :column),
      end_line: fetch_member(loc, :last_line),
      end_column: fetch_member(loc, :last_column),
      offset_start: loc&.expression&.begin_pos,
      offset_end: loc&.expression&.end_pos,
      code: extract_code_snippet(loc, code)
    }
    if current_depth >= max_depth
      state[:truncated] += 1
      state[:first_type] ||= node.type.to_s
      return {type: node.type.to_s, meta_data: meta_data, nested: true, truncated: true}
    end

    json_children = node.children.map do |child|
      if child.is_a?(Parser::AST::Node)
        ast_to_json(child, code, current_depth: current_depth + 1, file_path: file_path,
          max_depth: max_depth, state: state) # Recursively process child nodes
      else
        child # If it's not a node (e.g., literal), return as-is
      end
    end
    base_hash = {
      type: node.type.to_s, # Node type (e.g., :send, :def, etc.)
      meta_data: meta_data,
      children: json_children
    }
    add_node_properties(node.type, base_hash, file_path)
    # Truncated nodes keep their documented {type, meta_data, nested, truncated} shape, which is
    # why this happens after the truncation return above.
    metadata = syntax_metadata(node.type, loc)
    base_hash.merge!(metadata) unless metadata.empty?
    # Statement lists live at every level (file root, class/module bodies, method bodies), and a
    # `sig` block attaches to the def that follows it in the same list, so the check runs on
    # every node's children (plan 02 §3).
    mark_sig_attachments(node, json_children)
    base_hash
  end

  # Marks `has_sig: true` on a def/defs whose immediately preceding sibling in the same
  # statement list is a Sorbet `sig` block (`sig { params(...).returns(...) }` parses as a block
  # on `send nil, :sig`). The consumer otherwise has to stitch the two statements by position.
  # Like the other syntax facts, the key is emitted only when the fact holds.
  def self.mark_sig_attachments(parent_node, json_children)
    raw_children = parent_node.children
    return unless raw_children.is_a?(Array)

    json_children.each_with_index do |json_child, index|
      next if index.zero?
      next unless sig_block?(raw_children[index - 1])
      next unless json_child.is_a?(Hash) && !json_child[:truncated] && %w[def defs].include?(json_child[:type])

      json_child[:has_sig] = true
    end
  end

  # True for every statement Sorbet accepts as a signature, all of which are a `sig` block
  # somewhere underneath:
  #
  #   sig { void }                          block on `send nil, :sig`
  #   sig(:final) { void }                  arguments are irrelevant
  #   sig { void }.checked(:never)          the block is the receiver of a trailing send chain
  #   T::Sig::WithoutRuntime.sig { void }   sig called on a constant path
  #
  # The trailing-send and constant-receiver forms are the reason this is not a single shape test:
  # missing them marks a real signature as absent, and a consumer reading has_sig as authoritative
  # (chen does) would type those methods as untyped.
  def self.sig_block?(node)
    return false unless node.is_a?(Parser::AST::Node)

    case node.type
    when :block then sig_call?(node.children[0])
    when :send then sig_block?(node.children[0]) # `.checked(:never)` and friends
    else false
    end
  end

  def self.sig_call?(node)
    node.is_a?(Parser::AST::Node) &&
      node.type == :send &&
      node.children[1] == :sig &&
      sig_receiver?(node.children[0])
  end

  # No receiver (`extend T::Sig`), or a constant path such as T::Sig::WithoutRuntime. Anything
  # else — `helper.sig { }` — is some other DSL, not a signature.
  def self.sig_receiver?(receiver)
    return true if receiver.nil?

    receiver.is_a?(Parser::AST::Node) && receiver.type == :const &&
      (receiver.children[0].nil? || sig_receiver?(receiver.children[0]))
  end

  def self.trim_string(string)
    string.tr("\n", " ").gsub(/(\s)+/, " ")
  end

  def self.extract_code_snippet(location, source_code)
    return nil unless location

    range = location.expression || location
    return nil unless range.is_a?(Parser::Source::Range)

    snippet = source_code[range.begin_pos...range.end_pos]
    trim_string(snippet.strip)
  end

  def self.add_node_properties(node_type, base_map, file_path)
    children = base_map.delete(:children)

    case node_type
    when :def
      base_map[:name] = children[0]
      base_map[:arguments] = children[1]
      base_map[:body] = children[2]
    when :defs
      base_map[:base] = children[0]
      base_map[:name] = children[1]
      base_map[:arguments] = children[2]
      base_map[:body] = children[3]

    when :class
      base_map[:name] = children[0]
      base_map[:superclass] = children[1] if children[1]
      base_map[:body] = children[2]
    when :sclass
      base_map[:name] = children[0]
      base_map[:def] = children[1]
      base_map[:body] = children[2]
    when :module
      base_map[:name] = children[0]
      base_map[:body] = children[1]

    when :if
      base_map[:condition] = children[0]
      base_map[:then_branch] = children[1]
      base_map[:else_branch] = children[2] if children[2]
    when :while, :while_post
      base_map[:condition] = children[0]
      base_map[:body] = children[1]
    when :for, :for_post
      base_map[:variable] = children[0]
      base_map[:collection] = children[1]
      base_map[:body] = children[2]
    when :block
      base_map[:call_name] = children[0]
      base_map[:arguments] = children[1]
      base_map[:body] = children[2]
    when :begin
      base_map[:body] = children
    when :kwbegin
      base_map[:body] = children
    when :case
      base_map[:case_expression] = children[0]
      base_map[:when_clauses] = children[1..-2]
      base_map[:else_clause] = children[-1] if children[-1]
    when :when
      base_map[:conditions] = children[0..-2]
      base_map[:then_branch] = children[-1]
    when :unless
      base_map[:condition] = children[0]
      base_map[:then_branch] = children[1]
    when :until, :until_post
      base_map[:condition] = children[0]
      base_map[:body] = children[1]
    when :rescue, :case_match
      base_map[:statement] = children[0]
      base_map[:bodies] = children[1..-2]
      base_map[:else_clause] = children[-1] if children[-1]
    when :match_as
      base_map[:value] = children[0]
      base_map[:as] = children[1]
    when :in_pattern
      base_map[:pattern] = children[0]
      base_map[:guard] = children[1]
      base_map[:body] = children[2]
    when :const_pattern
      base_map[:const] = children[0]
      base_map[:pattern] = children[1]
    when :if_guard, :unless_guard
      base_map[:condition] = children[0]
    when :match_alt
      base_map[:left] = children[0]
      base_map[:right] = children[1]
    when :match_current_line
      base_map[:value] = children[0]
    when :match_with_trailing_comma
      base_map[:value] = children[0]
    when :resbody
      base_map[:exec_list] = children[0]
      base_map[:exec_var] = children[1]
      base_map[:body] = children[2]
    when :ensure
      base_map[:statement] = children[0]
      base_map[:body] = children[1]
    when :regopt, *REFS, :redo
      base_map[:value] = children[0] if children[0]
    when :return
      base_map[:values] = children if children[0]
    when *CONTROL_KW
      base_map[:arguments] = children[0] if children[0]
    when *FORWARD_ARGUMENTS, :empty_else, :lambda, :retry, :zsuper, :match_nil_pattern
      # refer to :type
    when *QUAL_ACCESS
      base_map[:base] = children[0]
      base_map[:lhs] = children[1]
      base_map[:rhs] = children[2]
    when :op_asgn
      base_map[:lhs] = children[0]
      base_map[:op] = children[1]
      base_map[:rhs] = children[2]
    when *ASSIGNMENTS
      base_map[:lhs] = children[0]
      base_map[:rhs] = children[1] if children[1]
    when *BIN_OP
      base_map[:lhs] = children[0]
      base_map[:rhs] = children[1]
    when *SINGLETONS
      base_map[:value] = node_type
    when *KW_ARGUMENTS
      base_map[:key] = children[0]
      base_map[:value] = children[1]
    when *LITERALS, *ARGUMENTS, *ACCESS, :arg_expr, :blockarg_expr, :match_rest,
      :numargs, :objc_restarg, :objc_varargs, :restarg_expr
      base_map[:value] = children[0]
    when :cbase
      base_map[:base] = children[0]
      base_map[:name] = children[1]

    when *CALLS
      base_map[:receiver] = children[0]
      base_map[:name] = children[1]
      base_map[:arguments] = children[2..] # Variable arguments
    when :index
      base_map[:receiver] = children[0]
      base_map[:arguments] = children[1..]
    when :indexasgn
      base_map[:receiver] = children[0]
      base_map[:arguments] = children[1...-1] || []
      base_map[:value] = children[-1]
    when *SPECIAL_CMD
      base_map[:arguments] = children

    when :pair, :optarg
      base_map[:key] = children[0]
      base_map[:value] = children[1]
    when :objc_kwarg
      base_map[:key] = children[0]
      base_map[:value] = children[1]
    when :const
      base_map[:base] = children[0]
      base_map[:name] = children[1]
    when :alias
      base_map[:alias] = children[0]
      base_map[:name] = children[1]
    when :regexp
      base_map[:value] = children[0]
      base_map[:opt] = children[1]
    when *RANGE_OP
      base_map[:start] = children[0]
      base_map[:end] = children[1]
    when :itblock
      base_map[:call] = children[0]
      base_map[:param] = children[1]
      base_map[:body] = children[2]
    when :numblock
      base_map[:call] = children[0]
      base_map[:param_idx] = children[1]
      base_map[:body] = children[2]

    when :masgn
      base_map[:lhs] = children[0]
      base_map[:rhs] = children[1]

    when :preexe, :postexe
      base_map[:body] = children[0]

    when :pin
      base_map[:value] = children[0]

    when *COLLECTIONS, *DYNAMIC_LITERALS
      # put :children back
      base_map[:children] = children

    else
      RubyAstGen::Logger.warn "Unhandled AST node type: #{node_type} - #{file_path}"
      base_map[:children] = children
    end
  end
end