require "spec_helper"

RSpec.describe AsanaWhisperer::Audio do
  let(:audio) { described_class.new }

  # Stub out the dependency checks so tests don't need ffmpeg/pactl installed
  before do
    allow(audio).to receive(:command_exists?).and_return(true)
  end

  # ── #detect_sources! ───────────────────────────────────────────────────────

  describe "#detect_sources!" do
    def pactl_output(*names)
      names.each_with_index.map do |name, i|
        "#{i + 1}\t#{name}\tsome-module\ts16le 2ch 44100Hz\tSUSPENDED"
      end.join("\n") + "\n"
    end

    it "detects RDPSource as mic and RDPSink.monitor as system audio" do
      allow(audio).to receive(:`).and_return(
        pactl_output("RDPSink.monitor", "RDPSource")
      )
      audio.detect_sources!

      expect(audio.mic_source).to eq("RDPSource")
      expect(audio.monitor_source).to eq("RDPSink.monitor")
    end

    it "detects a source with 'input' in the name as mic" do
      allow(audio).to receive(:`).and_return(
        pactl_output("alsa_output.default.monitor", "alsa_input.default")
      )
      audio.detect_sources!

      expect(audio.mic_source).to eq("alsa_input.default")
      expect(audio.monitor_source).to eq("alsa_output.default.monitor")
    end

    it "prefers an 'input' source over the fallback when both exist" do
      allow(audio).to receive(:`).and_return(
        pactl_output("alsa_output.default.monitor", "alsa_input.default", "RDPSource")
      )
      audio.detect_sources!

      expect(audio.mic_source).to eq("alsa_input.default")
    end

    it "falls back to first non-monitor source when no 'input' source exists" do
      allow(audio).to receive(:`).and_return(
        pactl_output("RDPSink.monitor", "RDPSource")
      )
      audio.detect_sources!

      expect(audio.mic_source).to eq("RDPSource")
    end

    it "sets monitor_source to nil when no .monitor source exists" do
      allow(audio).to receive(:`).and_return(pactl_output("RDPSource"))
      audio.detect_sources!

      expect(audio.monitor_source).to be_nil
    end

    it "raises when pactl returns no output" do
      allow(audio).to receive(:`).and_return("")

      expect { audio.detect_sources! }
        .to raise_error(/Could not query PulseAudio/)
    end

    it "raises when pactl is not installed" do
      allow(audio).to receive(:command_exists?).with("pactl").and_return(false)
      allow(audio).to receive(:command_exists?).with("ffmpeg").and_return(true)

      expect { audio.detect_sources! }.to raise_error(/Missing required tools.*pactl/)
    end

    it "raises when ffmpeg is not installed" do
      allow(audio).to receive(:command_exists?).with("pactl").and_return(true)
      allow(audio).to receive(:command_exists?).with("ffmpeg").and_return(false)

      expect { audio.detect_sources! }.to raise_error(/Missing required tools.*ffmpeg/)
    end
  end

  # ── #monitor_available? ────────────────────────────────────────────────────

  describe "#monitor_available?" do
    it "returns true when a monitor source was detected" do
      allow(audio).to receive(:`).and_return(
        "1\tRDPSink.monitor\tmod\ts16le\tSUSPENDED\n2\tRDPSource\tmod\ts16le\tSUSPENDED\n"
      )
      audio.detect_sources!
      expect(audio.monitor_available?).to be true
    end

    it "returns false when no monitor source was detected" do
      allow(audio).to receive(:`).and_return(
        "1\tRDPSource\tmod\ts16le\tSUSPENDED\n"
      )
      audio.detect_sources!
      expect(audio.monitor_available?).to be false
    end
  end

  # ── #describe_sources ──────────────────────────────────────────────────────

  describe "#describe_sources" do
    before do
      allow(audio).to receive(:`).and_return(
        "1\tRDPSink.monitor\tmod\ts16le\tSUSPENDED\n2\tRDPSource\tmod\ts16le\tSUSPENDED\n"
      )
      audio.detect_sources!
    end

    it "includes the mic source name" do
      expect(audio.describe_sources).to include("RDPSource")
    end

    it "includes the monitor source name" do
      expect(audio.describe_sources).to include("RDPSink.monitor")
    end

    it "shows a WSL2 warning when no monitor source is available" do
      allow(audio).to receive(:`).and_return("1\tRDPSource\tmod\ts16le\tSUSPENDED\n")
      audio.detect_sources!

      expect(audio.describe_sources).to include("not available")
    end
  end

  # ── #start_recording! / #stop_recording! ──────────────────────────────────

  describe "#start_recording!" do
    before do
      allow(audio).to receive(:`).and_return(
        "1\tRDPSink.monitor\tmod\ts16le\tSUSPENDED\n2\tRDPSource\tmod\ts16le\tSUSPENDED\n"
      )
      audio.detect_sources!
      allow(audio).to receive(:spawn_ffmpeg).and_return(12345, 12346)
    end

    it "records file paths for both streams" do
      audio.start_recording!
      expect(audio.files[:mic]).to end_with("mic.mp3")
      expect(audio.files[:monitor]).to end_with("system.mp3")
    end

    it "sets the start time" do
      audio.start_recording!
      expect(audio.start_time).to be_within(1).of(Time.now)
    end

    it "passes the stream key to spawn_ffmpeg so logs are named correctly" do
      expect(audio).to receive(:spawn_ffmpeg).with(anything, anything, :mic).and_return(1)
      expect(audio).to receive(:spawn_ffmpeg).with(anything, anything, :monitor).and_return(2)
      audio.start_recording!
    end
  end

  # ── #ffmpeg_error ──────────────────────────────────────────────────────────

  describe "#ffmpeg_error" do
    before do
      allow(audio).to receive(:`).and_return(
        "1\tRDPSink.monitor\tmod\ts16le\tSUSPENDED\n2\tRDPSource\tmod\ts16le\tSUSPENDED\n"
      )
      audio.detect_sources!
      allow(audio).to receive(:spawn_ffmpeg) do |_src, _out, key|
        # Write a fake ffmpeg log for the :mic stream
        if key == :mic
          log = File.join(audio.output_dir, "ffmpeg_#{key}.log")
          File.write(log, "Some header\nError: No such file or directory\n")
          audio.instance_variable_get(:@ffmpeg_logs)[key] = log
        end
        99999
      end
      audio.start_recording!
    end

    it "returns relevant error lines from the ffmpeg log" do
      expect(audio.ffmpeg_error(:mic)).to include("No such file or directory")
    end

    it "returns nil when no log file exists for a stream" do
      expect(audio.ffmpeg_error(:monitor)).to be_nil
    end
  end
end
