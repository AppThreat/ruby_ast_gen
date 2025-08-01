# frozen_string_literal: true

module NodeHandling
  MAX_NESTING_DEPTH = 100

  SINGLETONS = %i[nil true false].freeze
  LITERALS = %i[int float rational complex str sym].freeze
  CALLS = %i[send csend].freeze
  DYNAMIC_LITERALS = %i[dsym dstr].freeze
  CONTROL_KW = %i[break next].freeze
  ARGUMENTS = %i[arg restarg blockarg kwrestarg shadowarg].freeze
  KW_ARGUMENTS = %i[kwarg kwnilarg kwoptarg].freeze
  REFS = %i[nth_ref back_ref].freeze
  FORWARD_ARGUMENTS = %i[forward_args forwarded_args forward_arg].freeze
  ASSIGNMENTS = %i[or_asgn and_asgn lvasgn ivasgn gvasgn cvasgn match_with_lvasgn].freeze
  BIN_OP = %i[and or match_pattern match_pattern_p].freeze
  ACCESS = %i[self ident lvar cvar gvar ivar splat kwsplat block_pass
    match_var].freeze
  QUAL_ACCESS = [:casgn].freeze
  COLLECTIONS = %i[args array hash mlhs hash_pattern array_pattern
    array_pattern_with_tail find_pattern undef procarg0].freeze
  SPECIAL_CMD = %i[yield super defined? xstr].freeze
  RANGE_OP = %i[erange irange eflipflop iflipflop].freeze

  def self.fetch_member(loc, method)
    loc.public_send(method)
  rescue
    -1
  end

  def self.ast_to_json(node, code, current_depth: 0, file_path: nil)
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
    if current_depth >= MAX_NESTING_DEPTH
      RubyAstGen::Logger.warn "Reached max JSON depth on a #{node.type} node"
      return {type: node.type.to_s, meta_data: meta_data, nested: true}
    end

    base_hash = {
      type: node.type.to_s, # Node type (e.g., :send, :def, etc.)
      meta_data: meta_data,
      children: node.children.map do |child|
        if child.is_a?(Parser::AST::Node)
          ast_to_json(child, code, current_depth: current_depth + 1, file_path: file_path) # Recursively process child nodes
        else
          child # If it's not a node (e.g., literal), return as-is
        end
      end
    }
    add_node_properties(node.type, base_hash, file_path)
    base_hash
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
    when :if_guard, :unless_guard
      base_map[:condition] = children[0]
    when :match_alt
      base_map[:left] = children[0]
      base_map[:right] = children[1]
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
    when *FORWARD_ARGUMENTS, :retry, :zsuper, :match_nil_pattern
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
    when *LITERALS, *ARGUMENTS, *ACCESS, :match_rest
      base_map[:value] = children[0]
    when :cbase
      base_map[:base] = children[0]
      base_map[:name] = children[1]

    when *CALLS
      base_map[:receiver] = children[0]
      base_map[:name] = children[1]
      base_map[:arguments] = children[2..] # Variable arguments
    when *SPECIAL_CMD
      base_map[:arguments] = children

    when :pair, :optarg
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
      base_map[:body] = children[1]
    when :numblock
      base_map[:call] = children[0]
      base_map[:param_idx] = children[1]
      base_map[:body] = children[2]

    when :masgn
      base_map[:lhs] = children[0]
      base_map[:rhs] = children[1]

    when :preexe, :postexe
      base_map[:body] = children[0]

    when :kwnilarg
      base_map[:call] = node_type.to_s
      base_map[:body] = false
    when :kwrestarg
      base_map[:name] = children[0]
      if children[1]
        base_map[:value] = children[1]
      end

    when :pin
      base_map[:value] = children[0]

    when *COLLECTIONS, *DYNAMIC_LITERALS, *REFS
      # put :children back
      base_map[:children] = children

    else
      RubyAstGen::Logger.warn "Unhandled AST node type: #{node_type} - #{file_path}"
      base_map[:children] = children
    end
  end
end
