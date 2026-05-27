require 'fileutils'
require 'json'
require 'thread'

require_relative 'ruby_ast_gen/version'
require_relative 'ruby_ast_gen/node_handling'

module RubyAstGen

  module Logger

    def self.debug(message)
      puts "[DEBUG] #{message}"
    end

    def self.info(message)
      puts "[INFO] #{message}"
    end

    def self.warn(message)
      puts "[WARN] #{message}"
    end

    def self.error(message)
      puts "[ERR] #{message}"
    end
  end

  # Main method to parse the input and generate the AST output
  def self.parse(opts)
    if opts[:debug]
      RubyAstGen::Logger::debug "CLI Arguments received: #{opts}"
    end

    input_path = opts[:input]
    output_dir = opts[:output]
    exclude_regex = Regexp.new(opts[:exclude])

    if opts[:debug]
      RubyAstGen::Logger::debug "Exclude Regex Received: #{exclude_regex}"
    end

    FileUtils.mkdir_p(output_dir)

    if File.file?(input_path)
      process_file(input_path, output_dir, exclude_regex, input_path)
    elsif File.directory?(input_path)
      process_directory(input_path, output_dir, exclude_regex)
    else
      RubyAstGen::Logger::info "#{input_path} is neither a file nor a directory."
      exit 1
    end
  end

  private

  # Process a single file and generate its AST
  def self.process_file(file_path, output_dir, exclude_regex, base_dir)
    # Get the relative path of the file to apply exclusion rules
    relative_path = file_path.sub(%r{^.*\/}, '')
    relative_input_path = file_path.sub("#{base_dir}/", '')
    # Skip if the file matches the exclusion regex
    if exclude_regex && exclude_regex.match?(relative_input_path)
      RubyAstGen::Logger::debug "Excluding: #{relative_input_path}"
      return
    end

    return unless ruby_file?(file_path) # Skip if it's not a Ruby-related file

    begin
      ast = parse_file(file_path, relative_input_path)
      return unless ast

      output_path = File.join(output_dir, "#{relative_path}.json")

      File.write(output_path, JSON.generate(ast))
    rescue StandardError => e
      RubyAstGen::Logger::info "'#{relative_input_path}' - #{e.message}"
    end
  end

  def self.process_directory(dir_path, output_dir, exclude_regex, max_threads = 10)
    threads = []
    queue = Queue.new

    Dir.glob("#{dir_path}/**/*").each do |path|
      next unless File.file?(path) && ruby_file?(path)
      relative_dir = path.sub("#{dir_path}/", '')
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

            process_file(path, output_subdir, exclude_regex, dir_path)
          rescue => e
            RubyAstGen::Logger::info "Error processing #{path}: #{e.message}"
          end
        end
      end
    end

    threads.each(&:join)
  end

  def self.parser_for_current_ruby(log: true)
    current_version = Gem::Version.new(RUBY_VERSION)
    prism_cutoff = Gem::Version.new("3.4.0")

    require 'parser/source/buffer'

    if current_version < prism_cutoff
      require 'parser/current'
      parser = ::Parser::CurrentRuby
    else
      begin
        require 'prism'
        require 'prism/translation'
      rescue LoadError
        require 'parser/current'
        parser = ::Parser::CurrentRuby
      else
        parser = prism_translation_parser_for(current_version)
        unless parser
          require 'parser/current'
          parser = ::Parser::CurrentRuby
        end
      end
    end

    RubyAstGen::Logger.debug "Using parser: #{parser}" if log
    parser
  end

  def self.parser_info
    parser = parser_for_current_ruby(log: false)

    {
      ruby_engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby",
      ruby_version: RUBY_VERSION,
      ruby_platform: RUBY_PLATFORM,
      parser_backend: parser.to_s,
      parser_gem_version: Gem.loaded_specs["parser"]&.version&.to_s,
      prism_gem_version: Gem.loaded_specs["prism"]&.version&.to_s,
      prism_translation_parsers: prism_translation_parser_names
    }
  end

  def self.parser_info_text
    info = parser_info
    [
      "Ruby engine: #{info[:ruby_engine]}",
      "Ruby version: #{info[:ruby_version]}",
      "Ruby platform: #{info[:ruby_platform]}",
      "Parser backend: #{info[:parser_backend]}",
      "Parser gem: #{info[:parser_gem_version] || 'unavailable'}",
      "Prism gem: #{info[:prism_gem_version] || 'unavailable'}",
      "Prism translation parsers: #{info[:prism_translation_parsers].empty? ? 'none' : info[:prism_translation_parsers].join(', ')}"
    ].join("\n")
  end

  def self.prism_translation_parser_for(version)
    major = version.segments[0]
    minor = version.segments[1]
    parser_class_name = "Parser#{major}#{minor}"

    if defined?(::Prism::Translation) && ::Prism::Translation.const_defined?(parser_class_name)
      return ::Prism::Translation.const_get(parser_class_name)
    end

    candidates = ::Prism::Translation.constants.filter_map do |const_name|
      match = const_name.to_s.match(/\AParser(\d)(\d+)\z/)
      next unless match

      [match[1].to_i, match[2].to_i, ::Prism::Translation.const_get(const_name)]
    end
    target = [major, minor]
    candidates.select { |candidate_major, candidate_minor, _parser| [candidate_major, candidate_minor] <= target }
      .max_by { |candidate_major, candidate_minor, _parser| [candidate_major, candidate_minor] }&.last ||
      candidates.max_by { |candidate_major, candidate_minor, _parser| [candidate_major, candidate_minor] }&.last
  end

  def self.prism_translation_parser_names
    return [] unless defined?(::Prism::Translation)

    ::Prism::Translation.constants.grep(/\AParser\d+\z/).map(&:to_s).sort
  end

  def self.parse_file(file_path, relative_input_path)
    parser = parser_for_current_ruby
    code = File.read(file_path)
    ast = parser.parse(code)
    return unless ast
    json_ast = NodeHandling::ast_to_json(ast, code, file_path: relative_input_path)
    json_ast[:file_path] = file_path
    json_ast[:rel_file_path] = relative_input_path
    json_ast
  rescue ::Parser::SyntaxError => e
    RubyAstGen::Logger.info "Failed to parse #{file_path}: #{e.message}"
    nil
  end

  def self.ruby_file?(file_path)
    ext = File.extname(file_path)
    %w[.rb .gemspec Rakefile .rake .ru].include?(ext) || file_path.end_with?('.rb')
  end

end
