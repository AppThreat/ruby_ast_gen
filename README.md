# RubyAstGen

A Ruby parser than dumps the AST as JSON output. Uses both the
[`parser` gem](https://github.com/whitequark/parser/tree/90e0a4e2be86b02c423c77337adcfccdf6dd611b) and prism gem, thus supports
parsing Ruby version 1.8, 1.9, 2.0, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 3.0, 3.1, 3.2, 3.3, 3.4, and 4.0 syntax with
backwards-compatible AST formats.

## Usage

The release uses JRuby to enable an effective standalone version. Using `jruby`, one can run

```
jruby -S bundle install
jruby -S bundle exec exe/ruby_ast_gen
```

If using the JAR file, instead you can run

```
curl 'https://repo1.maven.org/maven2/org/jruby/jruby-complete/9.4.8.0/jruby-complete-9.4.8.0.jar' \
    --output jruby.jar
java -jar jruby.jar \
    -S gem install bundler --install-dir vendor/bundle/jruby/3.1.0
java -jar jruby.jar -s vendor/bundle/jruby/3.1.0/bin/bundle install
java -jar jruby.jar -S vendor/bundle/jruby/3.1.0/bin/bundle exec exe/ruby_ast_gen
```

The commands are as follows:

```
usage: ruby_ast_gen [options]
    -i, --input <path>       The input file or directory (required)
    -o, --output <dir>       The output directory (default: '.ast')
    -e, --exclude <regex>    The exclusion regex (default: '^(tests?|vendor|spec)')
    -l, --log <level>        The logging level: debug, info, warn or error (default: info)
    -d, --debug              Enable debug logging (same as --log debug)
        --parser-target <x.y>
                             Parse with a specific Ruby grammar (e.g. 3.4, 4.0) instead
                             of the newest available
        --max-depth <n>      Maximum AST depth before truncation (default: 250)
        --threads <n>        Worker threads for a directory run (default: 10)
        --parser-info        Print parser/runtime capability information
        --version            Print the version
        --help               Print usage
```

Debug logging is off by default; `-d` (or `-l debug`) turns it on, and `-l` applies to the
argument warnings themselves, so `-l error` makes a run silent unless it fails. An unrecognized
flag, log level, `--max-depth`, or `--threads` value prints a warning and the run continues, as
does an option whose value is missing. Only usage errors exit non-zero: a missing `-i`, an input
path that is neither a file nor a directory, an unusable `--exclude` regex, or an invalid
`--parser-target`. Problems with individual files are
reported and skipped, never fatal — the consumer treats a non-zero exit as "no files parsed at all".

To inspect which parser backend will be used in the current runtime, run:

```bash
exe/ruby_ast_gen --parser-info
```

## Parser selection

Parsing is independent of the running Ruby VM, so the backend is chosen by grammar capability
rather than runtime version. The effective backend is recorded in the top-level `parser_backend`
key of every generated JSON file (alongside `generator_version` and `ruby_version`):

- When the `prism` gem is available, the **newest grammar** its translation layer supports is
  used regardless of the running Ruby version — e.g. a Ruby 3.1 runtime can parse Ruby 4.0
  source (leading `&&`/`||` continuation lines).
- `--parser-target x.y` pins the grammar instead, resolved in order of fidelity:
  1. the prism translation grammar for exactly that version (e.g. `3.4` →
     `Prism::Translation::Parser34`);
  2. the `parser` gem grammar for exactly that version — prism only translates recent grammars,
     so `2.7` → `Parser::Ruby27` and `1.8` → `Parser::Ruby18`;
  3. the closest older prism grammar, and finally the newest available.
     A missing minor version is treated as `.0` (`--parser-target 4` means 4.0).
- If a file fails with a syntax error under the selected grammar, parsing is retried once with
  the newest grammar before the file is skipped (skipped when that is the grammar that just
  failed).
- Without the `prism` gem, the `parser` gem's `Parser::CurrentRuby` is used (runtime-version
  grammar).

`--parser-info` reports the resolved backend and grammar level, and honours `--parser-target`
given in any order:

```bash
exe/ruby_ast_gen --parser-info --parser-target 3.2
```

Note that the two backends disagree on Ruby 3.4's `it` block parameter: the prism translation
emits an `itblock` node (`call`, `param: "it"`, `body`) whose body references `lvar(:it)`, while
the `parser` gem grammars parse `it` as a plain method call (`send(nil, :it)`). Consumers should
check `parser_backend` before interpreting `it`.

## Recognized files and encodings

Directory scans pick up `.rb`, `.gemspec`, `.rake`, `.ru`, `.rbi`, `.thor`, `.jbuilder`,
`.axlsx`, and `.rabl` files, plus Ruby DSL files matched by basename in any directory:
`Rakefile`, `Gemfile`, `Capfile`, `Thorfile`, `Guardfile`, `Berksfile`, `Podfile`,
`Vagrantfile`, `Steepfile`, `Puppetfile`, `Dangerfile`, `Fastfile`, `Appfile`, `Pluginfile`,
`Matchfile`, `Scanfile`, `Snapfile`, `Gymfile`, `Deliverfile`, `Brewfile`, `.irbrc`, `.pryrc`,
and `.simplecov`. Both are matched
case-insensitively (`rakefile` and `app/models.RB` are picked up), but basenames must match
exactly rather than by prefix, so `Gemfile` is parsed while `Gemfile.lock` is not.

Dotfiles and dot-directories are scanned (`.ci/deploy.rb`, `.irbrc`), except for a fixed list of
tool and vendor directories matched by exact path component: `.git`, `.svn`, `.hg`, `.bundle`,
`.gem`, `.cache`, `.venv`, `.tox`, `.idea`, `.vscode`. Symlinked directories are not followed.
The exclusion regex is matched against the path relative to the input — for a single-file input
that is the file's basename, so a pattern matching some parent directory of an absolute path
cannot silently drop the file. An empty or comments-only file parses to nothing and produces no
JSON, as it always has.

Sources are read as bytes and decoded the way Ruby does, honouring `# coding:` magic comments,
so latin-1 and other legacy encodings parse correctly. Content that cannot be decoded is
degraded rather than dropped: bytes that are invalid under the declared encoding are scrubbed,
and a magic comment naming an unusable encoding falls back to reading the file as UTF-8. Either
way the file is still emitted, with invalid sequences replaced and the top-level
`encoding_scrubbed: true` marker set — which is also set when a decoded-but-binary payload (for
example from a `# coding: ASCII-8BIT` file) had to be replaced to be serializable.

Source nested deeper than `--max-depth` (default 250) AST levels is truncated rather than
dropped: the boundary node carries `truncated: true` (alongside the legacy `nested: true`), the
top level of the file counts the truncation points as `truncated_nodes: <count>` (each one stands
for a dropped subtree, so it is a count of cuts rather than of lost nodes), and one
`[WARN]` line per affected file names the first truncated node type. JSON serialization uses a
nesting limit derived from the same cap, so a file at the cap always serializes (JSON's own
default limit would otherwise drop files nested deeper than ~49 levels).

## Magic comments and call syntax metadata

Every emitted file carries a top-level `magic_comments` array (empty when the source has none):
`{"name": "typed", "value": "strict", "line": 1}`, in source order. A `#` comment whose entire
text is a `key: value` pair is reported when it appears in the file prologue — before the first
line of code, which is the only place Ruby honours such a comment. Sorbet strictness levels,
`frozen_string_literal`, `coding`, and custom tool flags in the header all come through as data,
while an RDoc line or commented-out code further down the file does not (`# https://example.com`
is a comment, not a magic comment). Values are single tokens; double-quoted values keep only
their content (`# coding: "utf-8"` → `utf-8`). The comments are collected from the same parse as
the AST (no second parse), so an encoding-scrubbed file reports what was actually parsed. Files
with no code at all (comments only) produce no JSON, as before, so their comments are not
reported anywhere.

Send and safe-navigation nodes carry explicit call syntax facts, so consumers don't have to
guess from the whitespace-normalized `code` snippet: `call_operator` (`"."`, `"::"`, or `"&."`)
when the call has an explicit operator, and `has_parentheses: true` when it was written with
parentheses. Percent-notation arrays carry `percent_array` (`"%w"`, `"%i"`, `"%W"`, `"%I"`,
whatever the delimiter), and heredoc strings carry `heredoc: true` plus
`heredoc_body_start`/`heredoc_body_end` character offsets — `meta_data.code` still covers only
the `<<~SQL` marker, so those offsets are the only way to reach the body text. All of these keys
are emitted only when the fact holds (the plain form stays key-less), and both parser backends
emit identical values.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can
also run `bin/console` for an interactive prompt that will allow you to experiment.

The test suite includes a syntax fixture corpus under `spec/fixtures/syntax` and JSON shape contract specs. Add small
fixtures there when supporting new Ruby syntax; use a leading `# min_ruby: x.y.z` comment to declare the Ruby _grammar_
level the fixture needs. Fixtures are exercised whenever the selected grammar is new enough — not when the runtime is —
so Ruby 4.0 fixtures run on a 3.4 runtime backed by prism. For syntax no available grammar can parse yet, gate the spec
on capability (`SpecCapabilities.grammar_accepts?`) instead of adding a fixture that can never run. The JSON shape is a
cross-repo contract with the chen `ruby2atom` frontend — keep changes additive and pin new node shapes in
`spec/json_contract_spec.rb`.

To install this gem onto your local machine, run `bundle exec rake install`. To package, run `rake build`.

### Testing a local build with chen / atom

Consumers invoke the generator as **`rbastgen`**, which is not this gem's executable: it is a Node
wrapper shipped by [atom-parsetools](https://github.com/AppThreat/atom-parsetools) that runs a
bundled copy of `ruby_ast_gen` under a Ruby interpreter (3.4.x or 4.0.x). So the easiest way to put
a working branch in front of chen or atom is to leave `rbastgen` alone and repoint the wrapper:

```bash
export RUBY_ASTGEN_BIN=/path/to/ruby_ast_gen/exe/ruby_ast_gen
rbastgen --version   # reports this checkout's version
```

`RUBY_CMD` and `ATOM_RUBY_HOME` select the interpreter the wrapper uses.

Where the wrapper is not involved, chen 3.1.1 and later can be pointed at any executable instead,
which a working branch needs because the frontend usually runs inside another process:

```bash
RBASTGEN_PATH=/path/to/rbastgen        # environment variable
sbt -Drbastgen.path=/path/to/rbastgen  # or system property
```

A standalone executable of this repo is a two-line script, since `exe/ruby_ast_gen` needs the
bundle:

```bash
cat > /usr/local/bin/rbastgen <<'SH'
#!/bin/sh
exec env BUNDLE_GEMFILE=/path/to/ruby_ast_gen/Gemfile \
  bundle exec ruby /path/to/ruby_ast_gen/exe/ruby_ast_gen "$@"
SH
chmod +x /usr/local/bin/rbastgen
```

atom's end-to-end Ruby suite (`RubyAtomWorkflowTests`) cancels itself unless the reachable
generator reports version 2.x, since a generator that cannot parse still exits 0 and would
otherwise look like an atom with nothing in it.
