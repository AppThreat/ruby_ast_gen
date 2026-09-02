# frozen_string_literal: true

require "tempfile"
require "tmpdir"

RSpec.describe "RubyAstGen::Logger levels" do
  # debug/info/warn/error must stay the methods call sites invoke (spec/syntax_fixture_spec.rb
  # pins `not_to receive(:warn)`), with the level check inside each method.
  it "keeps debug quiet and prints info/warn/error at the default :info level" do
    expect(RubyAstGen::Logger.level).to eq(:info)
    expect { RubyAstGen::Logger.debug("quiet") }.not_to output.to_stdout
    expect { RubyAstGen::Logger.info("n") }.to output(/\[INFO\] n\n/).to_stdout
    expect { RubyAstGen::Logger.warn("w") }.to output(/\[WARN\] w\n/).to_stdout
    expect { RubyAstGen::Logger.error("e") }.to output(/\[ERR\] e\n/).to_stdout
  end

  it "prints debug once the level is :debug" do
    RubyAstGen::Logger.level = :debug
    expect { RubyAstGen::Logger.debug("loud") }.to output(/\[DEBUG\] loud\n/).to_stdout
  end

  it "hides messages ranked below the configured level" do
    RubyAstGen::Logger.level = :warn
    expect { RubyAstGen::Logger.info("hidden") }.not_to output.to_stdout
    expect { RubyAstGen::Logger.warn("shown") }.to output(/\[WARN\] shown\n/).to_stdout
    expect { RubyAstGen::Logger.error("also shown") }.to output(/\[ERR\] also shown\n/).to_stdout
  end

  it "accepts case-insensitive level names" do
    RubyAstGen::Logger.level = "WARN"
    expect(RubyAstGen::Logger.level).to eq(:warn)
  end

  it "warns and falls back to :info for an unknown level instead of failing" do
    expect { RubyAstGen::Logger.level = :banana }.to output(/Unknown log level :banana/).to_stdout
    expect(RubyAstGen::Logger.level).to eq(:info)
  end

  it "restores the default level on reset_level!" do
    RubyAstGen::Logger.level = :debug
    RubyAstGen::Logger.reset_level!
    expect(RubyAstGen::Logger.level).to eq(:info)
  end

  it "applies the level from parse options before logging anything" do
    file = Tempfile.new(["log_level", ".rb"])
    begin
      file.write("x = 1")
      file.flush
      Dir.mktmpdir do |out_dir|
        expect do
          RubyAstGen.parse(input: file.path, output: out_dir, exclude: "ZZZNOMATCH", debug: true)
        end.to output(/\[DEBUG\] CLI Arguments received:/).to_stdout
        expect(File).to exist(File.join(out_dir, "#{File.basename(file.path)}.json"))
      end
    ensure
      file.close
      file.unlink
    end
  end
end
