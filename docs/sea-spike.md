# Single-executable spike: findings for issues #16, #17 and #18

Run on 2026-11-03/04. Branch `spike/sea-executables-16-17-18`. All numbers come from
CI run [41749225726](https://github.com/AppThreat/ruby_ast_gen/actions/runs/41749225726)
(all seven legs green) unless a row says otherwise. Executables carry CRuby 4.0.7 and were
pressed with tebako v2.8.68. The measurement harness is `build/sea-measure.sh`.

Test machines: Apple Silicon Mac (macOS 26, Docker Desktop for the Linux arm64 rows),
Parallels Windows 11 ARM64 VM (4 cores, 16 GB) for everything Windows.
**Not measured:** native Linux x86_64 timings (x86_64 binaries were only started under
emulation), a real Intel Mac (Rosetta only), a real `windows-11-arm` GitHub runner.

## What had to change before any leg built (tebako v2.1.8 → v2.8.68)

| Finding | Evidence | Change on this branch |
| --- | --- | --- |
| Runtime 4.0.6 on macOS arm64 cannot be fetched with v2.8.68: the runtime release `v0.16.32-ruby4.0` has no `.asc` for `tebako-runtime-0.16.32-4.0.6-macos-arm64.tar.gz`, and tebako refuses an unsigned runtime. 4.0.5 and 4.0.7 have it. | CI run 41737612256, macOS arm64 leg | Default runtime is now 4.0.7 |
| musl legs: Ruby's `configure` (run to provision the SDK) dies with `bad substitution` under Alpine's busybox `sh`. | CI run 41737612256, both musl legs | `apk add bash` and `/bin/sh -> bash` in the container |
| The `linux-gnu` binaries pressed on ubuntu-24.04 contain a `prism.so` that needs `GLIBC_2.33`. On glibc 2.31 (Ubuntu 20.04, Debian 11) `require "prism"` fails, and `ruby_ast_gen` silently falls back to the `parser` gem: `Parser::Ruby33` backend, grammar 3.3, no prism translation parsers, plus a warning on stderr. The release notes claim Ubuntu 20.04 support; the ELF starts there, but the AST is not the same. | `objdump -T` on the extracted `prism.so`; `--parser-info` in `ubuntu:20.04` | Linux gnu legs now press inside `ubuntu:20.04` (glibc 2.31, clang 10). Verified: backend is `Prism::Translation::Parser41` on Ubuntu 20.04 for both archs |
| Windows (#17): see below. | | Windows leg presses without a compiler |

## #16: Linux and macOS

### Output parity

Gem (Ruby 3.4.12 and Ruby 4.0.9 in Docker, `bundle exec`, prism 1.9.0) against the gnu-arm64
and musl-arm64 executables, and gem (Ruby 4.0.7, rbenv) against the macOS arm64 executable.
Inputs: the repo's syntax fixtures (9 AST files), `project_layout` (5), railsgoat (89),
maybe (599) and mastodon (2093) at the default depth. Counts include the manifest and the
diagnostics file.

- Per-file AST JSON: **byte-identical on all inputs** once `ruby_version` is masked. 0 files
  differ in any other way (2,795 AST files per executable, plus the manifest of each run).
- Without masking, every file differs, because the per-file JSON embeds `ruby_version`
  (`3.4.12` or `4.0.9` for the gem, `4.0.7` for the executable). Against the macOS gem
  running the same 4.0.7, only the manifest differs.
- The manifest differs between any two runs (`generated_at`, `output`), and its
  `ruby_version` differs as above. `parser_backend` is `Prism::Translation::Parser41` in both.
- Any `ruby_ast_gen_diagnostics.jsonl` in the output trees was compared with the rest (every file in
  both trees was diffed); none differed after masking.
- Consumers that read `ruby_version` from the JSON will see `4.0.7` regardless of the
  user's Ruby. Whether atom reads it was not checked (atom-parsetools#38/#59 should say).

### Grammar coverage

`--parser-target` resolves identically in the executable and the gem (both prism 1.9.0, macOS):
3.0, 3.1, 3.2 use the `parser` gem (`Parser::Ruby30/31/32`); 3.3 and 3.4 use
`Prism::Translation::Parser33/34`; 3.5 and 4.0 map to `Parser40`; 4.1 and above to `Parser41`.
Available prism translation parsers in the executable: Parser33, 34, 35, 40, 41. The gem
follows the runtime's prism, so it has the same set only when prism 1.9 is installed; the
Windows gem run in the VM (Ruby 3.4.10, default prism 1.5.3) had only Parser33 to 35.
The Windows executable ships prism 1.8.1 (see #17) and offers Parser33 to 41 as well.

### Cost

Size on disk (bytes, run 41749225726): gnu-x86_64 156.3 MB, gnu-arm64 155.4 MB,
musl-x86_64 123.3 MB, musl-arm64 122.3 MB, macOS-arm64 92.6 MB, macOS-x86_64 95.5 MB,
Windows-x64 85.0 MB. The vendored gem bundle in parsa is about 10 MB, so the executables
are 9 to 16 times larger.

**Every executable unpacks to disk on first run.** tebako 2.8.x executables are a small
bootstrap plus carried images; the first run copies the runtime and payload images into
`$TEBAKO_HOME` (default `~/.tebako`) and later runs reuse them:

| Platform | Unpacked | Cold `--version` | Warm `--version` |
| --- | --- | --- | --- |
| macOS arm64 | 86 MB | 0.64 s | 0.29 s |
| Linux gnu arm64 (Ubuntu 24.04 container) | 147 MB | 0.90 s | 0.26 s |
| Linux musl arm64 (Alpine) | 115 MB | not timed (busybox `date` has no `%N`) | not timed |
| Windows x64 (emulated on ARM64) | 78 MB | 1.50 s | 0.70 s |

The gem starts in about 0.1 s (0.14 s on the Windows VM).

Wall time and peak RSS, gem vs executable (Linux arm64 Docker, ruby:3.4, glibc build; the
musl and macOS rows are within noise of these):

| Input (files) | gem s | exe s | gem RSS | exe RSS |
| --- | --- | --- | --- | --- |
| syntax fixtures (10) | 0.20 | 0.31 | 40 MB | 137 MB |
| railsgoat (90) | 0.28 | 0.37 | 43 MB | 143 MB |
| maybe (600) | 1.28 | 1.16 | 60 MB | 174 MB |
| mastodon (2,094) | 3.85 | 3.11 | 76 MB | 221 MB |

On macOS arm64 (gem on Ruby 4.0.7): 0.13/0.35 s, 0.17/0.41 s, 0.94/1.16 s, 2.78/3.00 s for the
same four inputs; RSS 36 to 68 MB (gem) against 149 to 180 MB (exe). The executable adds
about 0.2 s per invocation and about 100 MB of RSS, and gets faster per file than the gem
only on large trees on Linux. For a per-file `parsa rb` invocation pattern that is a real
cost; for one run per project it is not.

Failure modes of the unpack (Linux, non-root, `ubuntu:24.04`; macOS behaves the same):

- Read-only `$HOME`: fails with `tebako-bootstrap: No such file or directory (os error 2)
  (writing .../.tebako/layout-version)`, exit non-zero. `TEBAKO_HOME=/writable/dir` fixes it.
- No `$HOME` and no `TEBAKO_HOME`: `cannot determine tebako home (set TEBAKO_HOME)`.
- `noexec` cache directory: `cannot execute runtime .../tebako-runtime-...: Permission denied`.
  The runtime is an ELF executed from the cache, so a `noexec` home cannot work.
- Eight concurrent cold starts on an empty home: all eight succeeded, one printed the
  unsigned-package warning. The lock handling works.
- Two different builds with the same package name and version in one cache print a
  `lazy seed ... DIFFERENT digest` warning; the run is unaffected (seen on macOS between a
  local and a CI build).
- Every run prints `runtime ruby-4.0.7 (cached)` to **stderr**, and the first run prints an
  "unsigned package" warning. stdout stays clean (`--version` printed only `2.1.0`).

### Environment

macOS arm64 executable, with rbenv Ruby 4.0.7 installed:

- `GEM_HOME`/`GEM_PATH` pointing at rbenv's gems: runs, backend `Parser41`.
- `RUBYLIB=<repo>/lib`: runs.
- `bundle exec <exe>` and `RUBYOPT=-rbundler/setup`: **fail** with
  `cannot load such file -- parser/source/buffer`, as `sea/entry.rb` documents. Whatever
  launches the executable (parsa) must remove `RUBYOPT`, `BUNDLE_*`, `GEM_*` and `RUBYLIB`
  from the child environment itself.
- rvm and chruby were not installed on the test machines. They export `GEM_HOME`,
  `GEM_PATH` and `RUBYLIB`-style variables, which the scrub covers; this was not run with the
  real tools.

Oldest glibc: after the press-container change, the gnu executables report the prism backend
on Ubuntu 20.04 (glibc 2.31) for both architectures (x86_64 under emulation). Anything older
(RHEL 8 is 2.28) was not tried. The tebako runtime itself needs `GLIBC_2.30`.

### Release hygiene compared with parsa

parsa's release workflow publishes `.sha256` files, a post-build CycloneDX SBOM (cdxgen,
validated with `cdx-validate`), a build-provenance attestation
(`actions/attest-build-provenance`), and ghcr.io copies. This repo's `release.yaml` has
checksums only. Missing: provenance attestation, an SBOM (the Gemfile.lock plus the pinned
runtime and tebako versions would be the inputs), and macOS notarization. The macOS
executable is ad-hoc signed (`codesign -dv`: `Signature=adhoc`); `spctl` rejects it, which
only matters for files that carry the quarantine attribute (browser downloads, not a Go
HTTP client). The tebako runtime download is signature-checked by tebako, but the pressed
executables themselves are unsigned ("carries no signature (unsigned package)" on every
first run; `tebako press --sign` exists).

### Recommendation for #16

`parsa rb` can run the executable on all six Linux and macOS targets if parsa:
1. sets `TEBAKO_HOME` to a writable, exec-capable directory it controls (for example under
   its own cache dir), and treats `Permission denied` / `os error 2` from the bootstrap as
   "fall back to the gem",
2. launches it with `RUBYOPT`, `BUNDLE_*`, `GEM_*` and `RUBYLIB` removed,
3. ignores stderr noise from the bootstrap,
4. accepts that `ruby_version` in the JSON is the bundled `4.0.7`.

Changes needed here first: merge the workflow changes on this branch (tebako v2.8.68,
runtime 4.0.7, musl bash, gnu press in `ubuntu:20.04`); add provenance and an SBOM; decide
on signing. Expect about 0.2 s and 100 MB RSS more per invocation than the gem.

## #17: Windows x64

Result: **a working Windows x64 executable is built in CI**
(`ruby_ast_gen-2.1.0-windows-ucrt64.exe`, 85.0 MB, smoke test in `sea.ps1` passes), with one
trade-off: it uses the prism gem bundled with the runtime (1.8.1) instead of 1.9.0.

What happened, in order:

1. Moving the pin to v2.8.68 changes the failure. The #486 symptom text ("TEBAKO_RUNTIME_IMAGE
   is not set") is still printed as a warning, but the build now gets past it and fails
   while compiling prism's extension: `make: *** No rule to make target
   '/C/Users/runneradmin/.tebako/deps/sdk/4.0.6-.../include/ruby.h', needed by 'api_node.o'`.
   The generated Makefile has an MSYS-style `/C/...` prerequisite path. It happened with the
   runner's `C:\mingw64` toolchain (the workflow's `C:\msys64\ucrt64` path does not exist on
   the runner, so the msys2 setup step was not even the compiler in use) and GNU Make 4.4.1
   built for mingw, so swapping `make` does not explain it.
2. On the Parallels VM (Windows 11 ARM64, x64 emulation) the same press fails earlier with
   the VM's mingw (MinGW-Builds gcc 16.1) and with MSYS2 ucrt64 gcc 16.2, with and without the
   older `mingw-w64-headers` r92 that CI used: `conflicting types for 'gettimeofday'` and
   `'shutdown'` between the SDK's `ruby/win32.h` and mingw's `sys/time.h` and `winsock2.h`.
   So the SDK headers and the mingw toolchain do not agree in this setup. Not resolved.
3. Avoiding the native build: prism is a default gem in the Ruby 4.0 runtime, so dropping
   `gem "prism"` from the pressed Gemfile (`SEA_BUNDLED_PRISM=1` in `build/sea.ps1`) installs
   only pure-Ruby gems, needs no compiler, and the press succeeds. In CI the Windows leg no
   longer installs msys2.
4. The executable then exposed a real bug in the Ruby code, not in tebako: with a native
   Windows input path (`-i C:\dir\file.rb`) a single file is written to
   `<out>/C:\dir\file.rb.json` (an invalid path, so nothing is written) and a directory input
   writes only the manifest. `process_file` splits on `/` only. Forward-slash paths work.
   The same bug exists in the gem (reproduced with Ruby 3.4.10 on the VM). Fixed on this
   branch by normalizing `File::ALT_SEPARATOR` in `RubyAstGen.parse`; verified on the VM with
   the gem. No test was added.

Measurements (the VM runs the x64 executable under Windows-on-Arm emulation, so absolute times
are pessimistic; no native x64 Windows machine was available):

| | Result |
| --- | --- |
| Parity vs the macOS executable (prism 1.9.0) | syntax fixtures and railsgoat: identical AST except absolute path strings (`file_path`, `__FILE__` literals) that come from the different input locations. `maybe` was not compared |
| Parity vs the gem | not compared directly; the VM gem used prism 1.5.3 |
| Grammar | `--parser-target` 3.3 / 3.4 / 4.0 / 4.1 select Parser33 / 34 / 40 / 41 |
| Size / unpacked | 85.0 MB / 78 MB |
| Cold / warm `--version` | 1.50 s / 0.70 s (gem: 0.14 s) |
| railsgoat / maybe (90 / 600 files) | 1.03 s / 3.88 s (gem on Ruby 3.4.10: 0.57 s / 2.94 s) |
| Hostile `GEM_HOME` / `RUBYLIB` | runs |

Not checked on Windows: peak RSS (the figure the script could read was only the launcher
process), read-only/noexec cache behaviour, concurrent cold starts.

Still open: why prism 1.9's extension cannot be built on Windows (the `/C/` path and the
header conflict above are both upstream-looking and were not reported upstream), and no
alternative packer (ocran etc.) was tried because the bundled-prism route works.

## #18: Windows arm64

Result: **no native arm64 executable can be built today; the x64 executable runs under
emulation.**

- tebako v2.8.68 publishes only `tebako-pkg`, `tfs` and `tebako-runtime-launcher` for
  `windows-ucrt-arm64`; the press driver (`tebako`) and `tebako-bootstrap` exist only for
  `windows-ucrt64`. tebako's own release script calls arm64 a "partial platform leg
  (roadmap 02 phase 2)". The three arm64 tools are real ARM64 PE binaries and start on the VM.
- The runtime is published: `tebako-runtime-0.16.32-4.0.7-windows-ucrt-arm64` (ABI
  `aarch64-mingw-ucrt`, 30 MB image). So pressing is the missing piece, not the runtime.
  Assembling a package by hand with `tebako-pkg bundle` was not attempted.
- RubyInstaller provides ARM64 builds (`rubyinstaller-4.0.9-1-arm.7z`, ABI `aarch64-mingw-ucrt`,
  includes prism 1.8.2 as a default gem); Ruby 4.0.9 ran natively on the VM. Installing the
  gem's `prism ~> 1.9` needs a compiler, and the plain 7z build has none (the devkit installer
  hung under `prlctl exec`, so a native-arm64 gem run was not obtained). `windows-11-arm`
  GitHub runners were not tried.
- The x64 executable measured above runs on Windows 11 ARM64 under its x64 emulation with the
  numbers in the #17 table. Native arm64 numbers do not exist, so the cost of emulation is
  unknown; the gem on the same VM was also x64 (Ruby 3.4.10 x64), so the gem-vs-exe comparison
  above is emulation against emulation.

Recommendation for #18: for `parsa` on Windows arm64, use the x64 executable (it works and
parity holds); revisit native arm64 when tebako ships `tebako` and `tebako-bootstrap` for
`windows-ucrt-arm64`. A CI job on `windows-11-arm` that runs the x64 artifact would pin this.

## Recommendation for #17

Publish the Windows x64 executable after it has been run on a real x64 Windows machine (only an
emulated one was available here), and after the release job's asset count (currently 6) and
`needs:` list are updated to include the Windows leg. Document that this asset carries prism
1.8.1 until prism 1.9 can be built on Windows.

## Reproducing

- Linux/macOS press: `TEBAKO_VERSION=v2.8.68 SEA_RUBY_VERSION=4.0.7 ./build/sea.sh`
  (`sea.sh` installs tebako into `~/.local/bin`).
- Windows press: `SEA_BUNDLED_PRISM=1 TEBAKO_VERSION=v2.8.68 SEA_RUBY_VERSION=4.0.7
  pwsh build/sea.ps1`.
- Parity and cost: `build/sea-measure.sh <exe> "<gem command>" <dirs...>`.
