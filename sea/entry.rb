#!/usr/bin/env ruby
# frozen_string_literal: true

# Entry point for the tebako-packaged single executable (see build/sea.sh).
#
# The packaged runtime ships its own gem home inside the VFS image, but RubyGems
# prefers GEM_HOME/GEM_PATH from the environment whenever they are set: on a
# machine that happens to have Ruby installed (rvm and chruby always export
# them), activation resolves parser/prism against the *host's* gems and the run
# dies with Gem::MissingSpecError. Drop the host's Ruby environment before the
# application requires anything gem-backed, and make RubyGems forget its
# memoized path resolution so the next lookup re-reads the now-clean ENV.
#
# RUBYOPT and RUBYLIB are consumed by the interpreter before this file runs,
# so deleting the variables alone defuses neither. RUBYOPT (a wrapping
# `bundle exec` exports -rbundler/setup) has already been required by the time
# application code starts and cannot be undone here — that remains the one
# documented way a Ruby-having machine can break the executable. RUBYLIB's
# damage, however, is only a set of entries the interpreter prepended to
# $LOAD_PATH at boot: ENV still names them, so remove exactly those paths and
# a host checkout can no longer shadow the packaged gems or the stdlib (both
# were reproducibly shadowable before this rejection: gem activation resolves
# against the *host's* gems first when GEM_* leak, and RUBYLIB entries sit
# ahead of the default load path in require's search order).
hostile_load_paths = (ENV["RUBYLIB"] || "").split(File::PATH_SEPARATOR)
  .flat_map { |path| [path, File.expand_path(path)] }.uniq
unless hostile_load_paths.empty?
  $LOAD_PATH.reject! do |path|
    hostile_load_paths.include?(path) || hostile_load_paths.include?(File.expand_path(path))
  end
end

%w[GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH RUBYOPT RUBYLIB].each do |key|
  ENV.delete(key)
end
Gem.clear_paths

# The executable always ships prism, so failing to load it means the host
# broke the native extension, not that prism is missing. tebako copies
# prism.so/prism.bundle into $TMPDIR at run time and loads it from there: with a
# noexec /tmp the load fails, and ruby_ast_gen falls back to the parser gem's
# Ruby 3.3 grammar while still exiting 0. The run continues on purpose (a
# non-zero exit costs the caller every file), but the cause is printed on
# stderr, since the parser gem's own warning does not name it.
begin
  require "prism"
rescue LoadError => e
  # prism.rb sets Prism::BACKEND before it requires the extension, and the
  # gem's own require "prism" re-runs that file; drop the constant so the retry
  # does not add an "already initialized constant" warning.
  Prism.send(:remove_const, :BACKEND) if defined?(Prism::BACKEND)
  warn "ruby_ast_gen: the bundled prism extension did not load (#{e.message}). " \
    "Falling back to the parser gem's older grammar. Native extensions are extracted " \
    "to the temporary directory at run time, so TMPDIR must point at a writable " \
    "directory that allows executing files."
end

load File.expand_path("../exe/ruby_ast_gen", __dir__)
