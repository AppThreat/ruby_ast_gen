# frozen_string_literal: true

module RubyAstGen
  # Command-line surface, kept in the library rather than in `exe/ruby_ast_gen` so it can be
  # tested without shelling out.
  #
  # FLAGS is the single source of truth: it drives argument parsing *and* renders `--help`, so
  # the two cannot drift. They used to be maintained separately, and the README documented
  # `-l/--log` for a release in which the argv loop rejected it with a non-zero exit.
  module CLI

    Flag = Struct.new(:short, :long, :kind, :key, :placeholder, :description, keyword_init: true) do
      def names
        [short, long].compact
      end

      # "-i, --input <path>" / "    --parser-info"
      def usage
        head = short ? "#{short}, #{long}" : "    #{long}"
        placeholder ? "#{head} #{placeholder}" : head
      end
    end

    # Worker count for directory runs. Exposed because the ceiling is memory, not CPU: a JRuby
    # container or a repo of very large files may need fewer (plan 03 §7).
    DEFAULT_THREADS = 10

    FLAGS = [
      Flag.new(short: "-i", long: "--input", kind: :value, key: :input, placeholder: "<path>",
               description: "The input file or directory (required)"),
      Flag.new(short: "-o", long: "--output", kind: :value, key: :output, placeholder: "<dir>",
               description: "The output directory (default: '.ast')"),
      Flag.new(short: "-e", long: "--exclude", kind: :value, key: :exclude, placeholder: "<regex>",
               description: "The exclusion regex (default: '^(tests?|vendor|spec)')"),
      Flag.new(short: "-l", long: "--log", kind: :value, key: :log_level, placeholder: "<level>",
               description: "The logging level: debug, info, warn or error (default: info)"),
      Flag.new(short: "-d", long: "--debug", kind: :boolean, key: :debug,
               description: "Enable debug logging (same as --log debug)"),
      Flag.new(long: "--parser-target", kind: :value, key: :parser_target, placeholder: "<x.y>",
               description: "Parse with a specific Ruby grammar (e.g. 3.4, 4.0) instead\nof the newest available"),
      Flag.new(long: "--max-depth", kind: :value, key: :max_depth, placeholder: "<n>",
               description: "Maximum AST depth before truncation " \
                            "(default: #{NodeHandling::MAX_NESTING_DEPTH})"),
      Flag.new(long: "--threads", kind: :value, key: :threads, placeholder: "<n>",
               description: "Worker threads for a directory run " \
                            "(default: #{DEFAULT_THREADS})"),
      Flag.new(long: "--fail-on-error", kind: :boolean, key: :fail_on_error,
               description: "Exit non-zero when any input file failed to parse"),
      Flag.new(long: "--parser-info", kind: :mode, key: :parser_info,
               description: "Print parser/runtime capability information"),
      Flag.new(long: "--version", kind: :mode, key: :version,
               description: "Print the version"),
      Flag.new(long: "--help", kind: :mode, key: :help,
               description: "Print usage")
    ].freeze

    BY_NAME = FLAGS.flat_map { |flag| flag.names.map { |name| [name, flag] } }.to_h.freeze

    DEFAULTS = {
      input: nil,
      output: ".ast",
      exclude: "^(tests?|vendor|spec)",
      debug: false,
      log_level: nil,
      parser_target: nil,
      max_depth: nil,
      threads: nil,
      fail_on_error: false
    }.freeze

    # Warnings are collected rather than printed so the caller can configure the log level
    # first: `-l error` would otherwise be unable to silence them, since they are produced
    # before the level is known.
    Result = Struct.new(:options, :mode, :warnings, keyword_init: true)

    def self.parse(argv)
      options = DEFAULTS.dup
      mode = :parse
      warnings = []

      index = 0
      while index < argv.size
        arg = argv[index]
        flag = BY_NAME[arg]

        case flag&.kind
        when :value
          value = argv[index + 1]
          # Only a *known flag* counts as a missing value. Testing for a leading "-" would
          # reject legitimate values such as an exclusion regex of "-vendor".
          if value.nil? || BY_NAME.key?(value)
            warnings << "Option #{arg} expects a value; got #{value.inspect}. Ignoring it."
          else
            options[flag.key] = value
            index += 1
          end
        when :boolean
          options[flag.key] = true
        when :mode
          mode = flag.key
        else
          # chen maps any non-zero exit to a failed command -> DefaultAstGenRunnerResult() ->
          # zero parsed files, i.e. an empty CPG (chen consumer plan 04 §10.1). An unrecognized flag must not
          # cost the user their whole atom, so warn and continue.
          warnings << "Unknown option: #{arg} (ignoring)"
        end

        index += 1
      end

      Result.new(options: options, mode: mode, warnings: warnings)
    end

    DESCRIPTION_COLUMN = 25

    def self.help_text
      lines = ["Usage:"]
      FLAGS.each do |flag|
        usage = flag.usage
        head, *rest = flag.description.split("\n")
        if usage.length < DESCRIPTION_COLUMN
          lines << "  #{usage.ljust(DESCRIPTION_COLUMN)}#{head}"
        else
          # No room on the flag's own line; start the description underneath it.
          lines << "  #{usage}"
          lines << "  #{' ' * DESCRIPTION_COLUMN}#{head}"
        end
        rest.each { |line| lines << "  #{' ' * DESCRIPTION_COLUMN}#{line}" }
      end
      lines.join("\n")
    end
  end
end
