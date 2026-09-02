require 'fileutils'
require 'json'
require 'thread'

require_relative 'ruby_ast_gen/version'
require_relative 'ruby_ast_gen/node_handling'
require_relative 'ruby_ast_gen/cli'

module RubyAstGen

  # All human-facing output goes through here, on stdout (chen captures it). Messages print when
  # their rank is at or above the configured level's rank, so the default :info keeps DEBUG quiet
  # instead of one line per file (plan 03 §10).
  module Logger

    LEVEL_RANKS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze
    private_constant :LEVEL_RANKS

    def self.level
      @level ||= :info
    end

    def self.level=(value)
      normalized = value.to_s.downcase.to_sym
      if LEVEL_RANKS.key?(normalized)
        @level = normalized
      else
        # A mistyped level is a configuration mistake, not a usage error: fall back to :info
        # rather than failing the run.
        @level = :info
        warn "Unknown log level #{value.inspect}; using :info."
      end
    end

    # Restores the default level. The level is process-global mutable state, so the test suite
    # resets it after every example.
    def self.reset_level!
      @level = nil
    end

    def self.debug(message)
      puts "[DEBUG] #{message}" if enabled?(:debug)
    end

    def self.info(message)
      puts "[INFO] #{message}" if enabled?(:info)
    end

    def self.warn(message)
      puts "[WARN] #{message}" if enabled?(:warn)
    end

    def self.error(message)
      puts "[ERR] #{message}" if enabled?(:error)
    end

    def self.enabled?(message_level)
      LEVEL_RANKS[level] <= LEVEL_RANKS[message_level]
    end
    private_class_method :enabled?
  end

  # Main method to parse the input and generate the AST output
  # Errors a single file may raise without ending the run: the consumer reads a non-zero exit as
  # "no files were parsed at all", so a per-file problem must never become one.
  #
  # SystemStackError is listed deliberately — it is not a StandardError, and raised inside a worker
  # thread it kills the thread and silently abandons the rest of its queue. JRuby needs one more:
  # when the stack runs out inside a *Java* frame (prism's node loading, which is where a deeply
  # nested literal lands) it raises java.lang.StackOverflowError, which is neither of the two. That
  # escaped every rescue here, aborted the run and exited non-zero — the failure mode this list
  # exists to prevent. Measured ceilings vary by runtime and by thread: the prism translation gives
  # up at ~5000 nested literals on CRuby's main thread but at ~250 in a JRuby worker with a 512 KB
  # stack, and serialization has its own ceiling (see .serialize) — all of them degrade to
  # log + skip.
  PER_FILE_ERRORS = begin
    errors = [StandardError, SystemStackError]
    errors << Java::JavaLang::StackOverflowError if RUBY_PLATFORM == "java"
    errors.freeze
  rescue NameError
    [StandardError, SystemStackError].freeze
  end

  def self.parse(opts)
    # Apply the level before anything can log, and specifically before the worker threads in
    # process_directory are spawned: they inherit whatever is configured here.
    Logger.level = :debug if opts[:debug]
    Logger.level = opts[:log_level] if opts[:log_level]

    Logger.debug "CLI Arguments received: #{opts}"

    input_path = opts[:input]
    output_dir = opts[:output]
    exclude_regex = validated_exclude(opts[:exclude])
    parser_target = validated_parser_target(opts[:parser_target])
    max_depth = validated_max_depth(opts[:max_depth])
    threads = validated_threads(opts[:threads])

    raise ArgumentError, "Error: '-i' or '--input' is required." if input_path.nil?

    Logger.debug "Exclude Regex Received: #{exclude_regex}"

    FileUtils.mkdir_p(output_dir)

    if File.file?(input_path)
      process_file(input_path, output_dir, exclude_regex, input_path, parser_target: parser_target,
        max_depth: max_depth)
    elsif File.directory?(input_path)
      process_directory(input_path, output_dir, exclude_regex, threads, parser_target: parser_target,
        max_depth: max_depth)
    else
      # Usage errors are raised, not logged-and-exited: the caller decides the exit status, and
      # the message must not be silenceable by --log (it is the only output of a failed run).
      raise ArgumentError, "#{input_path} is neither a file nor a directory."
    end
  end

  private

  # Raises rather than exiting: this is a library entry point, so a bad target is the caller's
  # error to surface. The CLI rescues this into the documented usage error (exit 1).
  def self.validated_parser_target(parser_target)
    return unless parser_target

    Gem::Version.new(parser_target)
  rescue ArgumentError
    raise ArgumentError, "Invalid --parser-target '#{parser_target}'. Expected a version like 3.4 or 4.0."
  end

  # An unusable exclusion regex is a usage error, like an invalid --parser-target: ignoring it
  # would silently parse everything the caller meant to skip, so it fails with a message rather
  # than a RegexpError backtrace. A missing value falls back to the documented default so the
  # library API can be called without it.
  def self.validated_exclude(pattern)
    Regexp.new(pattern || CLI::DEFAULTS[:exclude])
  rescue RegexpError, TypeError => e
    raise ArgumentError, "Invalid --exclude '#{pattern}': #{e.message}"
  end

  def self.validated_threads(value)
    return CLI::DEFAULT_THREADS unless value

    count = Integer(value.to_s, 10)
    return count if count >= 1

    raise ArgumentError
  rescue ArgumentError, TypeError
    Logger.warn "Invalid --threads '#{value}'; using the default of #{CLI::DEFAULT_THREADS}."
    CLI::DEFAULT_THREADS
  end

  # A bad depth is a configuration mistake, not a usage error: warn and fall back to the
  # default rather than failing the run (the same policy as an unknown --log level).
  def self.validated_max_depth(value)
    return NodeHandling::MAX_NESTING_DEPTH unless value

    depth = Integer(value.to_s, 10)
    return depth if depth >= 1

    raise ArgumentError
  rescue ArgumentError, TypeError
    Logger.warn "Invalid --max-depth '#{value}'; using the default of #{NodeHandling::MAX_NESTING_DEPTH}."
    NodeHandling::MAX_NESTING_DEPTH
  end
  # Process a single file and generate its AST
  def self.process_file(file_path, output_dir, exclude_regex, base_dir, parser_target: nil,
    max_depth: NodeHandling::MAX_NESTING_DEPTH)
    # Get the relative path of the file to apply exclusion rules
    relative_path = file_path.sub(%r{^.*\/}, '')
    # In single-file mode the caller passes the file itself as base_dir, so the sub below would be
    # a no-op and both the exclusion match and rel_file_path would see the *absolute* path: `-i
    # /tmp/x/keep.rb -e tmp` dropped the file because "tmp" appears in a directory component
    # (plan 03 §5). Only the path relative to the input is ever matched or reported.
    relative_input_path = if base_dir == file_path
      File.basename(file_path)
    else
      file_path.sub("#{base_dir}/", '')
    end
    # Skip if the file matches the exclusion regex
    if exclude_regex && exclude_regex.match?(relative_input_path)
      RubyAstGen::Logger.debug "Excluding: #{relative_input_path}"
      return
    end

    return unless ruby_file?(file_path) # Skip if it's not a Ruby-related file

    begin
      ast = parse_file(file_path, relative_input_path, parser_target: parser_target, max_depth: max_depth)
      return unless ast

      output_path = File.join(output_dir, "#{relative_path}.json")

      File.write(output_path, serialize(ast, max_depth))
    rescue *PER_FILE_ERRORS => e
      RubyAstGen::Logger.info "'#{relative_input_path}' - #{describe_error(e)}"
    end
  end

  # The stdlib generator, with a depth-safe fallback.
  #
  # max_nesting must exceed what a tree truncated at max_depth can reach: the default of 100 fails
  # at an AST depth of ~49 and the resulting JSON::NestingError used to drop the whole file (logged
  # as a per-file problem, exit 0) even though the AST itself was fine.
  #
  # How deep JSON.generate can go is a property of the runtime rather than of the JSON: CRuby's C
  # extension manages ~100_000 levels, but on TruffleRuby it runs through Sulong and a tree at the
  # default cap of 250 AST levels exhausts a worker thread's stack — which cost the whole file,
  # the one outcome the depth cap exists to prevent, and made the output depend on the interpreter.
  # Rather than guess each runtime's ceiling, fall back to the iterative writer when the recursive
  # one runs out of room: it is ~11x slower on a corpus of real files, so it earns its keep only
  # for the pathological ones. NodeHandling.dump_json is byte-identical to JSON.generate.
  def self.serialize(ast, max_depth)
    JSON.generate(ast, max_nesting: NodeHandling.json_nesting_limit(max_depth))
  rescue SystemStackError, JSON::NestingError
    NodeHandling.dump_json(ast)
  end

  # Java errors arrive with an empty message (JRuby's java.lang.StackOverflowError has none), so
  # the class name is the only thing that would tell the reader what happened.
  def self.describe_error(error)
    message = error.message.to_s
    message.empty? ? error.class.to_s : message
  end

  def self.process_directory(dir_path, output_dir, exclude_regex, max_threads = CLI::DEFAULT_THREADS,
    parser_target: nil, max_depth: NodeHandling::MAX_NESTING_DEPTH)
    threads = []
    queue = Queue.new

    # FNM_DOTMATCH: without it Dir.glob skips dotfiles and dot-directories entirely, so `.ci/*.rb`
    # and `.irbrc` were never parsed (plan 03 §5). SKIPPED_DIRECTORIES keeps that from pulling in
    # tool caches — a repo with `bundle config path .bundle` would otherwise hand us every
    # vendored gem, which the default exclusion regex does not cover.
    Dir.glob("#{dir_path}/**/*", File::FNM_DOTMATCH).each do |path|
      next unless File.file?(path) && ruby_file?(path)
      relative_dir = path.sub("#{dir_path}/", '')
      next if skipped_directory?(relative_dir)
      next if exclude_regex.match?(relative_dir)

      queue << path
    end

    max_threads.times do
      threads << Thread.new do
        until queue.empty?
          begin
            path = queue.pop(true) rescue nil # Non-blocking pop
            next unless path

            relative_path = path.sub(dir_path, '')
            output_subdir = File.join(output_dir, File.dirname(relative_path))
            FileUtils.mkdir_p(output_subdir)

            process_file(path, output_subdir, exclude_regex, dir_path, parser_target: parser_target,
              max_depth: max_depth)
          rescue *PER_FILE_ERRORS => e
            # Raised here rather than inside process_file's own rescue, this would kill the worker
            # and silently abandon the rest of its queue — join does not re-raise (plan 03 §7).
            RubyAstGen::Logger.info "Error processing #{path}: #{describe_error(e)}"
          end
        end
      end
    end

    threads.each(&:join)
  end

  PARSER_CACHE_MUTEX = Mutex.new
  private_constant :PARSER_CACHE_MUTEX

  # Resolves the parser class for a run. Parsing does not depend on the running Ruby VM, so the
  # grammar is picked by capability rather than by RUBY_VERSION: the newest grammar available by
  # default, or the one matching +parser_target+ when a target is requested. Memoized per target
  # because worker threads resolve this once per file.
  def self.parser_for_current_ruby(log: true, parser_target: nil)
    require 'parser/source/buffer'

    key = parser_target.nil? ? :newest : version_pair(parser_target)
    PARSER_CACHE_MUTEX.synchronize do
      cached = parser_cache[key]
      next cached if cached

      parser = key == :newest ? newest_available_parser : parser_for_target(key, log: log)
      RubyAstGen::Logger.debug "Using parser: #{parser}" if log
      parser_cache[key] = parser
    end
  end

  def self.parser_cache
    @parser_cache ||= {}
  end

  # Drops the memoized parser selections; only needed by tests that flip capabilities.
  def self.reset_parser_cache!
    PARSER_CACHE_MUTEX.synchronize { @parser_cache = {} }
  end

  # Grammar selection for an explicit target, in order of fidelity:
  #   1. the prism translation grammar for exactly that version
  #   2. the `parser` gem grammar for exactly that version (covers 1.8 - 3.4, which prism's
  #      translation layer does not expose)
  #   3. the closest older prism grammar
  #   4. the newest grammar available
  def self.parser_for_target(target, log: true)
    exact_prism = prism_translation_parser_named("Parser#{target[0]}#{target[1]}")
    return exact_prism if exact_prism

    exact_parser_gem = parser_gem_grammar_for(target)
    if exact_parser_gem
      RubyAstGen::Logger.debug "No prism grammar for Ruby #{target.join('.')}; using #{exact_parser_gem}" if log
      return exact_parser_gem
    end

    fallback = closest_prism_translation_parser(target) || newest_available_parser
    RubyAstGen::Logger.info "No grammar for Ruby #{target.join('.')}; using #{fallback}" if log
    fallback
  end

  # Newest grammar the installed gems can translate; the `parser` gem's runtime-version grammar
  # is the last resort, for runtimes without prism.
  def self.newest_available_parser
    newest_prism_translation_parser || current_ruby_parser
  end

  def self.current_ruby_parser
    require 'parser/current'
    ::Parser::CurrentRuby
  end

  def self.prism_available?
    return @prism_available unless @prism_available.nil?

    @prism_available =
      begin
        require 'prism'
        require 'prism/translation'
        true
      rescue LoadError
        false
      end
  end

  # The Ruby grammar level the selected parser implements, which is what decides whether a
  # given syntax parses — not RUBY_VERSION.
  def self.parser_grammar_version(parser = parser_for_current_ruby(log: false))
    match = parser.to_s.match(/(\d)(\d+)\z/)
    return Gem::Version.new(RUBY_VERSION) unless match

    Gem::Version.new("#{match[1]}.#{match[2]}")
  end

  def self.parser_info(parser_target: nil)
    parser = parser_for_current_ruby(log: false, parser_target: parser_target)

    {
      ruby_engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby",
      ruby_version: RUBY_VERSION,
      ruby_platform: RUBY_PLATFORM,
      parser_target: parser_target&.to_s,
      parser_backend: parser.to_s,
      grammar_version: parser_grammar_version(parser).to_s,
      parser_gem_version: Gem.loaded_specs["parser"]&.version&.to_s,
      prism_gem_version: Gem.loaded_specs["prism"]&.version&.to_s,
      prism_translation_parsers: prism_translation_parser_names
    }
  end

  def self.parser_info_text(parser_target: nil)
    info = parser_info(parser_target: parser_target)
    [
      "Ruby engine: #{info[:ruby_engine]}",
      "Ruby version: #{info[:ruby_version]}",
      "Ruby platform: #{info[:ruby_platform]}",
      "Parser target: #{info[:parser_target] || 'newest available'}",
      "Parser backend: #{info[:parser_backend]}",
      "Grammar version: #{info[:grammar_version]}",
      "Parser gem: #{info[:parser_gem_version] || 'unavailable'}",
      "Prism gem: #{info[:prism_gem_version] || 'unavailable'}",
      "Prism translation parsers: #{info[:prism_translation_parsers].empty? ? 'none' : info[:prism_translation_parsers].join(', ')}"
    ].join("\n")
  end

  # [major, minor] for anything version-ish; a missing minor is treated as 0 ("4" -> [4, 0]).
  def self.version_pair(version)
    version = Gem::Version.new(version.to_s) unless version.is_a?(Gem::Version)
    [version.segments[0].to_i, (version.segments[1] || 0).to_i]
  end

  def self.prism_translation_parser_named(name)
    return nil unless prism_available?
    return nil unless ::Prism::Translation.const_defined?(name, false)

    ::Prism::Translation.const_get(name, false)
  end

  def self.parser_gem_grammar_for(target)
    require "parser/ruby#{target[0]}#{target[1]}"
    ::Parser.const_get("Ruby#{target[0]}#{target[1]}", false)
  rescue LoadError, NameError
    nil
  end

  # Highest grammar that is not newer than the target, else nil.
  def self.closest_prism_translation_parser(target)
    candidates = prism_translation_parser_candidates
    not_newer = candidates.select { |major, minor, _parser| ([major, minor] <=> target) <= 0 }
    (not_newer.max_by { |major, minor, _parser| [major, minor] } ||
      candidates.max_by { |major, minor, _parser| [major, minor] })&.last
  end

  def self.prism_translation_parser_candidates
    return [] unless prism_available?

    ::Prism::Translation.constants.filter_map do |const_name|
      match = const_name.to_s.match(/\AParser(\d)(\d+)\z/)
      next unless match

      [match[1].to_i, match[2].to_i, ::Prism::Translation.const_get(const_name, false)]
    end
  end

  def self.newest_prism_translation_parser
    prism_translation_parser_candidates.max_by { |major, minor, _parser| [major, minor] }&.last
  end

  def self.prism_translation_parser_names
    return [] unless prism_available?

    ::Prism::Translation.constants.grep(/\AParser\d+\z/).map(&:to_s).sort
  end

  def self.parse_file(file_path, relative_input_path, parser_target: nil, max_depth: NodeHandling::MAX_NESTING_DEPTH)
    parser_class = parser_for_current_ruby(parser_target: parser_target)
    buffer, source_scrubbed = read_source_buffer(file_path)
    ast, comments, parser_class = parse_with_retry(parser_class, buffer, file_path)
    return unless ast

    # The truncation count is per-file state threaded through the traversal: module state would
    # race across the 10 worker threads and misattribute truncations between files.
    state = {truncated: 0, first_type: nil}
    json_ast = NodeHandling::ast_to_json(ast, buffer.source, file_path: relative_input_path,
      max_depth: max_depth, state: state)
    # Assigned before the UTF-8 walk so comment text from oddly-encoded sources is normalized
    # like every other payload. The comments come from the same parse as the AST, so a scrubbed
    # file's report matches what was actually parsed.
    json_ast[:magic_comments] = magic_comments(comments, ast)
    payloads_scrubbed = force_utf8_payloads!(json_ast)
    json_ast[:file_path] = file_path
    json_ast[:rel_file_path] = relative_input_path
    json_ast[:generator_version] = VERSION
    json_ast[:parser_backend] = parser_class.to_s
    json_ast[:ruby_version] = RUBY_VERSION
    json_ast[:truncated_nodes] = state[:truncated]
    json_ast[:encoding_scrubbed] = true if source_scrubbed || payloads_scrubbed
    if state[:truncated] > 0
      # One warning per file: the count and the node types live in the JSON, so a line per
      # truncated node is noise.
      Logger.warn "#{relative_input_path}: truncated #{state[:truncated]} node(s) at max depth " \
        "#{max_depth} (first: #{state[:first_type]})"
    end
    json_ast
  end

  # Reads the file as bytes and lets a parser source buffer decode it the way Ruby does, so a
  # `# coding:` magic comment (or BOM) is honoured instead of everything being force-read as
  # UTF-8. Undecodable content is degraded rather than dropped, in three tiers:
  #
  #   1. decode faithfully (magic comment / BOM respected);
  #   2. bytes invalid under the declared encoding (EncodingError) -> decode a scrubbed copy;
  #   3. encoding name unusable (Parser::UnknownEncodingInMagicComment, an ArgumentError) ->
  #      skip detection altogether and take the scrubbed bytes as UTF-8.
  #
  # The second return value marks tiers 2 and 3 as degraded. I/O errors are not caught here:
  # an unreadable file is the caller's problem to log, and swallowing them would report a
  # missing file as an encoding problem.
  def self.read_source_buffer(file_path)
    raw = File.binread(file_path)

    begin
      [decoded_source_buffer(file_path, raw), false]
    rescue EncodingError, ArgumentError
      begin
        [decoded_source_buffer(file_path, scrub_to_utf8(raw)), true]
      rescue EncodingError, ArgumentError
        [undecoded_source_buffer(file_path, scrub_to_utf8(raw)), true]
      end
    end
  end

  # Buffers built with +source=+ run the parser gem's encoding detection. The bytes are tagged
  # UTF-8 first so that a file *without* a magic comment keeps the encoding (and therefore the
  # character offsets) of the String this replaced; detection re-encodes from there when the
  # file says otherwise.
  def self.decoded_source_buffer(file_path, bytes)
    Parser::Source::Buffer.new(file_path, source: bytes.dup.force_encoding(Encoding::UTF_8))
  end

  # +raw_source=+ skips detection entirely, which is the only way to read a file whose declared
  # encoding cannot be resolved. It still normalises CRLF, so offsets stay consistent.
  def self.undecoded_source_buffer(file_path, utf8_source)
    buffer = Parser::Source::Buffer.new(file_path)
    buffer.raw_source = utf8_source
    buffer
  end

  def self.scrub_to_utf8(bytes)
    bytes.dup.force_encoding(Encoding::UTF_8).scrub
  end

  # Rewrites every String/Symbol payload in the emitted structure as valid UTF-8 so that
  # JSON.generate cannot fail, and reports whether anything had to be replaced. Needed even
  # when the source decoded cleanly: a `# coding: ASCII-8BIT` file is decoded faithfully (any
  # byte is valid in that encoding) and yields binary node values and code snippets, which
  # JSON.generate rejects. Top-level path keys are assigned after this walk, so file_path stays
  # byte-for-byte what the caller passed in.
  def self.force_utf8_payloads!(json_ast)
    state = { scrubbed: false }
    sanitize_utf8!(json_ast, state)
    state[:scrubbed]
  end

  # Returns the sanitized value so containers can re-assign it. The scrub flag is accumulated
  # in +state+ rather than folded out of the return values: combining them with `||=` would
  # short-circuit the recursive call and silently skip whole subtrees once one string had been
  # replaced (which shipped once, emitting JSON that still failed to serialize).
  # Walks the built JSON with an explicit stack rather than by recursion. The tree is as deep as
  # the AST (up to --max-depth), and recursion here cost ~2 frames per level: on runtimes with
  # smaller thread stacks (JRuby, TruffleRuby, Windows CRuby, and any worker thread) a deeply
  # nested file raised SystemStackError *after* the AST walk had already truncated correctly, so
  # the file was skipped by process_file — the one outcome the depth cap exists to prevent.
  # Iterating has no depth limit at all, so the scrub is no longer a reason to lose a file.
  def self.sanitize_utf8!(object, state)
    root = [object]
    pending = [root]

    until pending.empty?
      container = pending.pop
      case container
      when Hash
        container.each do |key, value|
          replacement, descend = sanitize_payload(value, state)
          container[key] = replacement
          pending << replacement if descend
        end
      when Array
        container.each_index do |index|
          replacement, descend = sanitize_payload(container[index], state)
          container[index] = replacement
          pending << replacement if descend
        end
      end
    end

    root.first
  end

  # Returns the value to store and whether it is a container the walk must descend into.
  def self.sanitize_payload(value, state)
    case value
    when Hash, Array
      [value, true]
    when String
      utf8, scrubbed = to_utf8(value)
      state[:scrubbed] = true if scrubbed
      [utf8, false]
    when Symbol
      utf8, scrubbed = to_utf8(value.to_s)
      state[:scrubbed] = true if scrubbed
      [scrubbed ? utf8.to_sym : value, false]
    else
      [value, false]
    end
  end

  def self.to_utf8(string)
    return [string, false] if string.encoding == Encoding::UTF_8 && string.valid_encoding?
    return [string.scrub, true] if string.encoding == Encoding::UTF_8

    [string.encode(Encoding::UTF_8), false]
  rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
    [string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace), true]
  end

  # Returns the parsed AST, the raw comment list, and the parser that produced them, so callers
  # can record the effective backend and derive magic comments from the parse that actually
  # succeeded — the retry may have swapped the grammar after a syntax error. Comments are
  # collected in the same lexing pass as the AST (parse_with_comments), so there is no second
  # parse; `Prism::Translation::Parser` implements the same method as the parser gem, which
  # keeps the extraction below backend-independent.
  def self.parse_with_retry(parser_class, buffer, file_path)
    ast, comments = parser_class.default_parser.parse_with_comments(buffer)
    [ast, comments, parser_class]
  rescue ::Parser::SyntaxError => e
    retry_class = syntax_retry_parser(parser_class)
    if retry_class.nil?
      RubyAstGen::Logger.info "Failed to parse #{file_path}: #{e.message}"
      return [nil, [], parser_class]
    end

    RubyAstGen::Logger.info "Retrying #{file_path} with #{retry_class} after: #{e.message.lines.first&.strip}"
    begin
      ast, comments = retry_class.default_parser.parse_with_comments(buffer)
      [ast, comments, retry_class]
    rescue ::Parser::SyntaxError => retry_error
      RubyAstGen::Logger.info "Failed to parse #{file_path}: #{retry_error.message}"
      [nil, [], retry_class]
    end
  end

  # Magic comments ("# key: value" comments) reported as data, in source order. The rule runs
  # over the comment tokens of the parse that produced the AST: the whole comment must be the
  # `key: value` pair (a trailing word makes it an ordinary comment), whitespace around the colon
  # is optional, and the comment must appear in the file prologue — before the first line of
  # code. Only `#` comments qualify: =begin/=end documents come back as type :document, never
  # magic comments, on both backends. Double-quoted values keep only their content; single quotes
  # are left as written.
  #
  # The prologue restriction is where this deliberately diverges from
  # `Prism.parse(...).magic_comments`, which is a lexical scan with no position rule and
  # therefore reports RDoc and commented-out code as magic comments (`# https://memcached.org`
  # → `{https => //memcached.org}`, `# See: docs`, `# attr_reader: foo`). Ruby only honours these
  # comments before any code — a `frozen_string_literal` after code is ignored with a warning,
  # and Sorbet's `typed:` sigil must precede code as well — so the prologue is what "magic"
  # means. Measured over 7 104 gem files: the restriction drops 1 472 of 7 094 reported entries
  # while keeping every one of the 5 430 real magic comments (frozen_string_literal, coding,
  # encoding, typed).
  MAGIC_COMMENT_PATTERN = /\A#\s*([A-Za-z0-9_-]+)\s*:\s*(\S+)[ \t]*\z/.freeze
  private_constant :MAGIC_COMMENT_PATTERN

  def self.magic_comments(comments, ast = nil)
    # Comments at or after the first byte of code are ordinary comments. When the root node has
    # no location to compare against (never seen in practice), position is not enforced rather
    # than dropping everything.
    first_code = ast&.location&.expression&.begin_pos

    comments.filter_map do |comment|
      next unless comment.is_a?(::Parser::Source::Comment) && comment.type == :inline
      next if first_code && comment.loc.expression.begin_pos >= first_code

      match = comment.text.match(MAGIC_COMMENT_PATTERN)
      next unless match

      value = match[2]
      # Double-quoted values keep only their content, matching how prism reports
      # `# coding: "utf-8"`.
      value = value[1..-2] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
      {name: match[1], value: value, line: comment.loc.line}
    end
  end

  # A file rejected by an older grammar may still be valid newer Ruby, so retry once with the
  # newest grammar available. Skipped when that is the grammar that just failed.
  def self.syntax_retry_parser(failed_parser)
    newest = newest_prism_translation_parser
    newest if newest && newest != failed_parser
  end

  # Files parsed as Ruby: well-known basenames of Ruby DSL files, in any directory, plus
  # Ruby-ish extensions. Both are matched case-insensitively (rake itself accepts `rakefile`),
  # but basename matching is exact rather than prefix-based, so "Gemfile" is parsed while
  # "Gemfile.lock" is not.
  RUBY_FILE_BASENAMES = %w[
    Rakefile Gemfile Capfile Thorfile Guardfile Berksfile Podfile Vagrantfile
    Steepfile Puppetfile Dangerfile Fastfile Appfile Pluginfile Matchfile Scanfile
    Snapfile Gymfile Deliverfile Brewfile
    .irbrc .pryrc .simplecov
  ].map(&:downcase).freeze
  private_constant :RUBY_FILE_BASENAMES

  # Dot-directories that hold tool state or vendored code rather than the project's own sources.
  # Matched by exact path component, so a project directory named `.ci` is still scanned.
  SKIPPED_DIRECTORIES = %w[.git .svn .hg .bundle .gem .cache .venv .tox .idea .vscode].freeze
  private_constant :SKIPPED_DIRECTORIES

  def self.skipped_directory?(relative_path)
    relative_path.split(File::SEPARATOR).any? { |part| SKIPPED_DIRECTORIES.include?(part) }
  end

  RUBY_FILE_EXTENSIONS = %w[.rb .gemspec .rake .ru .rbi .thor .jbuilder .axlsx .rabl].freeze
  private_constant :RUBY_FILE_EXTENSIONS

  def self.ruby_file?(file_path)
    basename = File.basename(file_path).downcase
    return true if RUBY_FILE_BASENAMES.include?(basename)

    RUBY_FILE_EXTENSIONS.include?(File.extname(basename))
  end

end
