# Build a self-contained single executable application (SEA) of ruby_ast_gen
# for Windows (x64, ucrt64 runtime) using tebako <https://tebako.org>.
#
# The PowerShell counterpart of build/sea.sh: one native .exe that carries the
# CRuby runtime, the gems (parser + prism with its native extension) and the
# application tree, so end users need neither Ruby nor Java installed.
#
# EXPERIMENTAL — this leg does not currently produce a shippable binary, and
# the release workflow therefore does not publish one. The cause is a single
# upstream bug, tamatebako/tebako#486: on windows-ucrt64 the runtime image and
# the payload image both declare a 'libwinpthread-1.dll' library alias, and the
# driver refuses the ambiguity rather than picking a winner. It surfaces twice,
# and the two faces are the same defect seen from opposite sides:
#
#   1. At press time, bundling prism fails with
#      "extconf failed: No such file or directory - A:/t/bin/ruby.exe" —
#      preceded by the driver's own "TEBAKO_RUNTIME_IMAGE is not set — booting
#      with no env image; the runtime root stays empty". The spawned extconf
#      child boots bare, so A:/t has no interpreter. Supplying the missing
#      TEBAKO_RUNTIME_IMAGE (spec 17 §1) by hand does mount the env image — and
#      the press then fails on the #486 alias collision instead, which is what
#      proves the two are one bug. A press of the same tree with a pure-Ruby
#      gem set (ostruct + parser, no prism) succeeds either way.
#   2. A package that does press fails at boot on that same alias collision.
#
# Reproduced on a native x64 GitHub runner and a local Windows box, under ruby
# 3.4.10 and 4.0.6, with runtimes 0.16.18 and 0.16.21, with all six published
# windows-ucrt64 assets installed and a wiped store — no combination avoids it.
# #486's documented workaround (pin the runtime to 0.16.9) is not available:
# tebako 2.1.8's registry publishes 0.16.17 and newer only, and the issue notes
# the workaround cannot help an app with a native-extension gem anyway, which
# is exactly what prism is.
#
# The script is kept working and correct so the leg turns back on with no
# further changes once tebako fixes these; the smoke tests below are what
# decides whether a build is shippable.
#
#   ./build/sea.ps1                     # press with the pinned defaults
#   ./build/sea.ps1 -RubyVersion 3.4.10
#
# SEA_RUBY_VERSION / TEBAKO_VERSION environment variables override the
# defaults when the parameters are omitted (that is how the release workflow
# feeds its dispatch input into this script).
#
# Prerequisites: a ucrt64 toolchain reachable on PATH (the release workflow
# provisions MSYS2's mingw-w64-ucrt-x86_64-gcc; tebako's runtime SDK compiles
# gem native extensions against its own headers at press time) and curl.exe,
# shipped with Windows.
param(
    [string]$RubyVersion = "",
    [string]$TebakoVersion = "",
    [string]$Dist = ""
)

$ErrorActionPreference = "Stop"

if (-not $RubyVersion) { $RubyVersion = $env:SEA_RUBY_VERSION }
if (-not $RubyVersion) { $RubyVersion = "4.0.6" }
if (-not $TebakoVersion) { $TebakoVersion = $env:TEBAKO_VERSION }
if (-not $TebakoVersion) { $TebakoVersion = "v2.1.8" }
# The value must carry the v: it names the release tag in the download URLs.
$TebakoVersion = "v" + $TebakoVersion.TrimStart("v")

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Dist) { $Dist = Join-Path $RepoRoot "dist" }
$Platform = "windows-ucrt64"
$GemVersion = (Select-String -Path (Join-Path $RepoRoot "lib/ruby_ast_gen/version.rb") `
    -Pattern 'VERSION = "(.*)"').Matches[0].Groups[1].Value
$Out = Join-Path $Dist "ruby_ast_gen-$GemVersion-$Platform.exe"

Write-Host "sea.ps1: ruby_ast_gen $GemVersion for $Platform (runtime $RubyVersion)"

# ---------------------------------------------------------------------------
# 1. tebako itself: the four .exe assets of the pinned release, SHA256-verified
#    (the same procedure build/sea.sh performs on unix).
# ---------------------------------------------------------------------------
$TebakoBin = Join-Path $env:USERPROFILE ".local\bin"
if (-not (Get-Command tebako -ErrorAction SilentlyContinue)) {
    Write-Host "sea.ps1: installing tebako $TebakoVersion"
    $base = "https://github.com/tamatebako/tebako/releases/download/$TebakoVersion"
    $vnum = $TebakoVersion.TrimStart("v")
    New-Item -ItemType Directory -Force -Path $TebakoBin | Out-Null
    $tmp = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "tebako-install")
    try {
        curl.exe -fsSL -o "$tmp\SHA256SUMS" "$base/SHA256SUMS"
        foreach ($name in "tebako", "tebako-pkg", "tfs", "tebako-bootstrap") {
            $asset = "$name-$vnum-$Platform.exe"
            curl.exe -fsSL -o "$tmp\$asset" "$base/$asset"
            $want = (Select-String -Path "$tmp\SHA256SUMS" -Pattern ([regex]::Escape($asset)) |
                Select-Object -First 1).Line.Split(" ")[0]
            $got = (Get-FileHash -Algorithm SHA256 "$tmp\$asset").Hash.ToLower()
            if ($got -ne $want) { throw "sha256 mismatch for $asset (want $want, got $got)" }
            Copy-Item "$tmp\$asset" "$TebakoBin\$name.exe" -Force
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
$env:PATH = "$TebakoBin;$env:PATH"
if (-not (Get-Command tebako -ErrorAction SilentlyContinue)) {
    throw "sea.ps1: tebako installed but not on PATH"
}

# ---------------------------------------------------------------------------
# 2. Build tree: a Gemfile root (see build/sea.sh for why the gemspec layout is
#    not pressable). press installs the gems inside the pinned runtime, so no
#    Ruby is needed on this machine either.
# ---------------------------------------------------------------------------
$BuildRoot = Join-Path $env:TEMP ("ruby-ast-gen-sea-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
try {
    foreach ($dir in "lib", "exe", "sea") {
        Copy-Item -Recurse (Join-Path $RepoRoot $dir) (Join-Path $BuildRoot $dir)
    }
    @"
# frozen_string_literal: true

# Runtime-only view of the repository Gemfile for the pressed executable: the
# parser/prism constraints must stay in sync with the Gemfile in the repo root
# (spec/sea_bundle_spec.rb fails the suite when they drift).
source "https://rubygems.org"

gem "ostruct", "~> 0.6.3"
gem "parser", "~> 3.3.12.0"
gem "prism", "~> 1.9"
"@ | Set-Content (Join-Path $BuildRoot "Gemfile")

    # -----------------------------------------------------------------------
    # 3. Press
    # -----------------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    if (Test-Path $Out) { Remove-Item $Out }
    # tebako appends .exe to whatever -o names on Windows, so hand it the
    # stem: passing $Out (which already ends in .exe) yields a file called
    # ...windows-ucrt64.exe.exe that nothing downstream here looks for.
    $OutStem = Join-Path (Split-Path -Parent $Out) `
        ([System.IO.Path]::GetFileNameWithoutExtension($Out))
    tebako press -r $BuildRoot -e sea/entry.rb -o $OutStem -R $RubyVersion -m self-contained
    # A native command's non-zero exit does not trip $ErrorActionPreference, so
    # without this check a failed press falls through into the smoke tests and
    # reports a missing executable instead of the press error that caused it.
    if ($LASTEXITCODE -ne 0) { throw "sea.ps1: tebako press failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $Out)) { throw "sea.ps1: press reported success but $Out does not exist" }

    # -----------------------------------------------------------------------
    # 4. Smoke tests (see build/sea.sh): the pristine leg runs with everything
    #    Ruby-ish scrubbed from the environment (the no-Ruby user; a process
    #    still needs the Windows-critical variables to start at all), the
    #    hostile leg adds foreign GEM_HOME/GEM_PATH plus a RUBYLIB whose
    #    parser/source/buffer.rb and json.rb are raising stubs — the regression
    #    guard for sea/entry.rb's environment scrub.
    # -----------------------------------------------------------------------
    $hostileDir = Join-Path $env:TEMP ("sea-hostile-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $hostileDir "parser\source") | Out-Null
    Set-Content -Path (Join-Path $hostileDir "parser\source\buffer.rb") `
        -Value 'raise "hostile RUBYLIB shadowed the packaged parser gem"'
    Set-Content -Path (Join-Path $hostileDir "json.rb") `
        -Value 'raise "hostile RUBYLIB shadowed the packaged stdlib"'

    $smokeDir = Join-Path $env:TEMP ("sea-smoke-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $smokeDir | Out-Null

    # The pristine leg: snapshot the environment, drop everything except the
    # variables process creation on Windows needs (and PowerShell's own module
    # path), run the checks, restore in finally.
    $saved = @{}
    foreach ($e in Get-ChildItem Env:) { $saved[$e.Name] = $e.Value }
    $keep = @("SYSTEMROOT", "SYSTEMDRIVE", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP",
        "HOMEDRIVE", "HOMEPATH", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "PROGRAMDATA",
        "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE", "PATH", "PSModulePath")
    try {
        foreach ($e in Get-ChildItem Env:) {
            if ($keep -notcontains $e.Name.ToUpper()) {
                Remove-Item -Path ("Env:\" + $e.Name) -ErrorAction SilentlyContinue
            }
        }

        $version = @(& $Out --version 2> $null)[-1]
        if ($version -ne $GemVersion) { throw "sea.ps1: --version returned '$version', expected '$GemVersion'" }

        $info = @(& $Out --parser-info 2> $null)
        if (-not ($info -match "Parser backend: Prism")) { throw "sea.ps1: prism backend not selected (pristine)" }
        if (-not ($info -match "Ruby version: $RubyVersion")) { throw "sea.ps1: runtime is not $RubyVersion (pristine)" }

        & $Out -i (Join-Path $RepoRoot "lib/ruby_ast_gen/version.rb") -o $smokeDir *> $null
        if ($LASTEXITCODE -ne 0) { throw "sea.ps1: parse run failed (pristine)" }
        if (-not (Test-Path (Join-Path $smokeDir "version.rb.json"))) { throw "sea.ps1: no JSON emitted for the fixture (pristine)" }
    } finally {
        foreach ($k in $saved.Keys) { Set-Item -Path ("Env:" + $k) -Value $saved[$k] }
    }

    # The hostile leg: foreign gem homes and a shadowing RUBYLIB.
    $env:GEM_HOME = "C:\sea-smoke-gem-home"
    $env:GEM_PATH = "C:\sea-smoke-gem-path"
    $env:RUBYLIB = $hostileDir
    try {
        $info = @(& $Out --parser-info 2> $null)
        if (-not ($info -match "Parser backend: Prism")) { throw "sea.ps1: prism backend not selected (hostile GEM_*/RUBYLIB)" }
        if (-not ($info -match "Ruby version: $RubyVersion")) { throw "sea.ps1: runtime is not $RubyVersion (hostile)" }
    } finally {
        Remove-Item Env:GEM_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GEM_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:RUBYLIB -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $hostileDir, $smokeDir -ErrorAction SilentlyContinue
    }
    Write-Host "sea.ps1: smoke test passed"

    # -----------------------------------------------------------------------
    # 5. Checksum
    # -----------------------------------------------------------------------
    $hash = (Get-FileHash -Algorithm SHA256 $Out).Hash.ToLower()
    "$hash  $(Split-Path -Leaf $Out)" | Set-Content "$Out.sha256"
    Write-Host ("sea.ps1: built {0} ({1:N1} MB)" -f (Split-Path -Leaf $Out), ((Get-Item $Out).Length / 1MB))
} finally {
    Remove-Item -Recurse -Force $BuildRoot -ErrorAction SilentlyContinue
}
