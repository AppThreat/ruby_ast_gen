# Build a self-contained single executable application (SEA) of ruby_ast_gen
# for Windows (x64, ucrt64 runtime) using tebako <https://tebako.org>.
#
# The PowerShell counterpart of build/sea.sh: one native .exe that carries the
# CRuby runtime, the gems (parser + prism) and the application tree, so end
# users need neither Ruby nor Java installed.
#
# EXPERIMENTAL — the release workflow builds this leg but does not publish it.
#
# History, because it explains the requirements below. With tebako v2.1.8 every
# press failed on tamatebako/tebako#486 (a duplicate 'libwinpthread-1.dll'
# alias between the runtime and payload images). The fix chain for
# tamatebako/tebako#753 (closed green at v2.8.44: a real ruby.exe spawn
# vehicle, the alias-clean child mount, the Windows SDK provisioning) landed
# all of that in the press driver, so with v2.8.77 the press gets as far as
# compiling prism's native extension and needs two things from the machine:
#
#   - an MSYS2 ucrt64 gcc FIRST on PATH (the runtime is ucrt; the legacy
#     msvcrt MinGW-Builds gcc compiles against the wrong ABI), and an MSYS
#     `make` (from msys2's own usr/bin) rather than mingw32-make, because the
#     Makefile mkmf generates carries MSYS-style '/C/...' prerequisite paths
#     that only an MSYS make resolves;
#   - the SDK config.h patch below: tebako's runtime-SDK artifacts (v0.2.38,
#     rolled into the registry on 2026-11-11/12) carry the build farm's
#     configure results, which define HAVE_SYS_TIME_H and leave
#     HAVE_SHUTDOWN undefined. RubyInstaller, which builds Ruby with mingw,
#     does the opposite, and Ruby's own public headers require that: with
#     HAVE_SYS_TIME_H set, ruby/missing.h includes mingw's sys/time.h and its
#     gettimeofday declaration collides with ruby/win32.h's ("conflicting
#     types"), and without HAVE_SHUTDOWN ruby/missing.h's own shutdown
#     declaration collides with winsock2.h's. The patch rewrites those three
#     lines to RubyInstaller's feature set after the press provisions the SDK
#     and before the gems build. Remove it once tebako's SDK carries a
#     mingw-compatible config.h (their nightly rails-windows leg pins
#     tebako 2.8.44 with pre-regression SDK artifacts, so it stays green
#     without this).
#
# v2.8.78 is deliberately not used: every binary in that release identifies
# itself as 2.8.77, so the pinned-version check below rejects it.
#
# SEA_BUNDLED_PRISM=1 still avoids the native build entirely: it drops prism
# from the pressed Gemfile, so only pure-Ruby gems are installed, no compiler
# is needed, and the executable uses the runtime's default prism gem (1.8.1 in
# runtime 4.0.7) instead of ~> 1.9. The smoke test then accepts that older
# prism and says so.
#
#   ./build/sea.ps1                     # press with the pinned defaults
#   ./build/sea.ps1 -RubyVersion 4.0.7
#   $env:SEA_BUNDLED_PRISM = "1"; ./build/sea.ps1
#
# SEA_RUBY_VERSION / TEBAKO_VERSION environment variables override the
# defaults when the parameters are omitted (that is how the release workflow
# feeds its dispatch input into this script). A tebako already on PATH is used
# only when it is the pinned version.
param(
    [string]$RubyVersion = "",
    [string]$TebakoVersion = "",
    [string]$Dist = ""
)

$ErrorActionPreference = "Stop"

if (-not $RubyVersion) { $RubyVersion = $env:SEA_RUBY_VERSION }
if (-not $RubyVersion) { $RubyVersion = "4.0.7" }
if (-not $TebakoVersion) { $TebakoVersion = $env:TEBAKO_VERSION }
if (-not $TebakoVersion) { $TebakoVersion = "v2.8.77" }
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
# 1. tebako itself, unless the pinned version is already on PATH: the four .exe
#    assets of the pinned release, SHA256-verified (the same procedure
#    build/sea.sh performs on unix). Any other tebako version is ignored.
# ---------------------------------------------------------------------------
$TebakoBin = Join-Path $env:USERPROFILE ".local\bin"
$vnum = $TebakoVersion.TrimStart("v")
function Test-PinnedTebako {
    if (-not (Get-Command tebako -ErrorAction SilentlyContinue)) { return $false }
    $tokens = (@(& tebako --version 2>$null) -join " ") -split '\s+' | ForEach-Object { $_.TrimStart("v") }
    return ($tokens -contains $vnum)
}
# A pinned copy installed by an earlier run wins over another version elsewhere on PATH.
if (Test-Path (Join-Path $TebakoBin "tebako.exe")) { $env:PATH = "$TebakoBin;$env:PATH" }
if (-not (Test-PinnedTebako)) {
    Write-Host "sea.ps1: installing tebako $TebakoVersion"
    $base = "https://github.com/tamatebako/tebako/releases/download/$TebakoVersion"
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
if (-not (Test-PinnedTebako)) {
    throw "sea.ps1: tebako $TebakoVersion installed, but PATH does not resolve to it"
}

# ---------------------------------------------------------------------------
# 1b. Toolchain preflight for the native prism build (see the header). With
#     SEA_BUNDLED_PRISM=1 no compiler is needed at all, so the checks are
#     skipped and the SDK patch job is not started.
# ---------------------------------------------------------------------------
$BundledPrism = $env:SEA_BUNDLED_PRISM -eq "1"
$SdkPatchJob = $null
if (-not $BundledPrism) {
    $gcc = Get-Command gcc -ErrorAction SilentlyContinue
    if (-not $gcc) {
        throw "sea.ps1: no gcc on PATH. Install the MSYS2 ucrt64 toolchain (mingw-w64-ucrt-x86_64-gcc) and put its ucrt64\bin first on PATH."
    }
    if ($gcc.Source -notmatch "ucrt64") {
        throw "sea.ps1: gcc resolved to $($gcc.Source), which is not the ucrt64 ABI the runtime is built for. Put the MSYS2 ucrt64\bin directory ahead of it."
    }
    $make = Get-Command make -ErrorAction SilentlyContinue
    if (-not $make) {
        throw "sea.ps1: no make on PATH. The MSYS make (msys2's usr\bin) is required: mingw32-make cannot resolve the '/C/...' prerequisite paths mkmf writes."
    }
    Write-Host "sea.ps1: gcc $($gcc.Source), make $($make.Source)"

    # The SDK config.h patch (see the header). tebako press provisions the SDK
    # and then builds the gems in one command, so the patch runs as a job that
    # waits for the file, rewrites the three feature defines and exits. It is
    # idempotent: a re-run on an already-patched SDK does nothing.
    $sdkDir = Join-Path $env:USERPROFILE ".tebako\deps\sdk"
    $rubyVer = $RubyVersion
    $SdkPatchJob = Start-Job -Name seaSdkPatch -ScriptBlock {
        param($sdkDir, $rubyVer)
        # The press reads config.h when the gems build, seconds after
        # provisioning writes it, so patch the moment the file appears and then
        # keep verifying: if provisioning rewrites it once more, patch again.
        # Writing goes through a temp file moved into place, so extconf never
        # observes a half-written config.h.
        $deadline = (Get-Date).AddMinutes(10)
        $patched = $false
        while ((Get-Date) -lt $deadline) {
            $cfg = Get-ChildItem -Path (Join-Path $sdkDir "$rubyVer-*-windows-ucrt64\archhdr\ruby\config.h") `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cfg) {
                $text = Get-Content $cfg.FullName -Raw
                if ($text -match "(?m)^#define HAVE_SYS_TIME_H 1") {
                    $text = $text -replace "(?m)^#define HAVE_SYS_TIME_H 1.*$",
                        "// sea.ps1 SDK patch (tebako-runtime-ruby v0.2.38 regression): RubyInstaller's mingw feature set`r`n#define HAVE_SHUTDOWN 1"
                    $tmp = "$($cfg.FullName).seapatch"
                    Set-Content -Path $tmp -Value $text -NoNewline
                    Move-Item -Path $tmp -Destination $cfg.FullName -Force
                    $patched = $true
                    Start-Sleep -Seconds 3
                    continue
                }
                if ($patched -and $text -match "sea\.ps1 SDK patch") {
                    return "patched and stable: $($cfg.FullName)"
                }
                if (-not $patched -and $text -match "sea\.ps1 SDK patch") {
                    return "no patch needed (already patched): $($cfg.FullName)"
                }
                if (-not $patched -and $text -notmatch "HAVE_SYS_TIME_H" -and $text -match "HAVE_SHUTDOWN") {
                    return "no patch needed (SDK fixed upstream): $($cfg.FullName)"
                }
            }
            Start-Sleep -Milliseconds 500
        }
        if ($patched) { return "patched but never observed stable: $($cfg.FullName)" }
        "timeout: the SDK config.h never appeared"
    } -ArgumentList $sdkDir, $rubyVer
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
gem "parser", "~> 3.3.13.0"
gem "prism", "~> 1.9"
"@ | Set-Content (Join-Path $BuildRoot "Gemfile")
    # SEA_BUNDLED_PRISM=1 drops the prism line so that no native extension is
    # compiled at press time and the runtime's default prism gem is used
    # instead (see the header). The release workflow never sets it on a tag.
    if ($BundledPrism) {
        (Get-Content (Join-Path $BuildRoot "Gemfile")) -notmatch '^gem "prism"' |
            Set-Content (Join-Path $BuildRoot "Gemfile")
    }
    # The prism floor the Gemfile asks for ("~> 1.9" -> 1.9), read from the
    # script's own copy so it cannot drift from the line above.
    $PrismMin = [version]((Select-String -Path $PSCommandPath -Pattern '^gem "prism", "~> (.*)"$').Matches[0].Groups[1].Value)

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
    # The SDK patch job's verdict, before anything else can throw. It reports
    # whether the patch landed (or was unnecessary) while the gems built.
    if ($SdkPatchJob) {
        Wait-Job -Job $SdkPatchJob -Timeout 30 | Out-Null
        Write-Host "sea.ps1: SDK patch job: $(Receive-Job -Job $SdkPatchJob)"
        Remove-Job -Job $SdkPatchJob -Force -ErrorAction SilentlyContinue
        $SdkPatchJob = $null
    }
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
        $prismLine = @($info -match '^Prism gem: ')[0]
        $prismVersion = if ($prismLine) { $prismLine -replace '^Prism gem: ', '' } else { "" }
        $prismOk = $prismVersion -match '^\d+(\.\d+)+$' -and [version]$prismVersion -ge $PrismMin
        if (-not $prismOk) {
            if (-not $BundledPrism) { throw "sea.ps1: prism is '$prismVersion', the pressed Gemfile asks for ~> $PrismMin" }
            Write-Host "sea.ps1: WARNING: SEA_BUNDLED_PRISM=1, so this executable carries the runtime's prism $prismVersion, not ~> $PrismMin"
        }

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
    if ($SdkPatchJob) {
        Stop-Job -Job $SdkPatchJob -ErrorAction SilentlyContinue
        Remove-Job -Job $SdkPatchJob -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $BuildRoot -ErrorAction SilentlyContinue
}
