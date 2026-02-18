require "tmpdir"

module AsanaWhisperer
  class Audio
    SAMPLE_RATE = "16000"
    CHANNELS    = "1"
    BITRATE     = "32k"

    attr_reader :mic_source, :monitor_source, :output_dir, :pids, :files, :start_time

    def initialize
      @pids        = {}
      @files       = {}
      @ffmpeg_logs = {}
      @output_dir  = Dir.mktmpdir("asana-whisperer-")
    end

    def detect_sources!
      check_dependencies!

      raw = `pactl list sources short 2>/dev/null`
      if raw.empty?
        raise "Could not query PulseAudio sources. Is PulseAudio running?\n" \
              "Try: pulseaudio --start"
      end

      names = raw.lines.map { |l| l.split[1] }.compact

      # Prefer explicit input/capture sources for mic; avoid monitors
      @mic_source = names.find { |s| s.match?(/input|capture/i) && !s.end_with?(".monitor") }
      @mic_source ||= names.reject { |s| s.end_with?(".monitor") }.first

      # System audio monitor (output sink loopback) — may not exist on WSL2
      @monitor_source = names.find { |s| s.end_with?(".monitor") }

      self
    end

    def start_recording!
      raise "No audio sources detected. Did you call detect_sources!?" unless mic_source

      @start_time = Time.now

      if mic_source
        @files[:mic] = File.join(output_dir, "mic.mp3")
        @pids[:mic]  = spawn_ffmpeg(mic_source, @files[:mic], :mic)
      end

      if monitor_source
        @files[:monitor] = File.join(output_dir, "system.mp3")
        @pids[:monitor]  = spawn_ffmpeg(monitor_source, @files[:monitor], :monitor)
      end

      self
    end

    def stop_recording!
      # Send INT to ffmpeg so it finalizes the file cleanly
      pids.each_value { |pid| Process.kill("INT", pid) rescue nil }
      pids.each_value { |pid| Process.wait(pid) rescue nil }
      @pids = {}
      self
    end

    def elapsed_seconds
      return 0 unless start_time
      (Time.now - start_time).to_i
    end

    def file_size_mb(key)
      path = files[key]
      return 0 unless path && File.exist?(path)
      (File.size(path) / 1_048_576.0).round(1)
    end

    def cleanup!
      FileUtils.rm_rf(output_dir)
    end

    def monitor_available?
      !monitor_source.nil?
    end

    # Returns the last few lines of ffmpeg's stderr for a stream, or nil if clean.
    def ffmpeg_error(key)
      log_path = @ffmpeg_logs[key]
      return nil unless log_path && File.exist?(log_path)
      lines = File.readlines(log_path).reject { |l| l.strip.empty? }
      # Skip the verbose ffmpeg header lines; surface only warnings/errors
      relevant = lines.select { |l| l.match?(/error|warning|invalid|no such|failed|refused/i) }
      relevant = lines.last(6) if relevant.empty?
      relevant.join.strip.then { |s| s.empty? ? nil : s }
    end

    def describe_sources
      lines = []
      lines << "  Microphone : #{mic_source || "(none found)"}"
      if monitor_source
        lines << "  System audio: #{monitor_source}"
      else
        lines << "  System audio: not available (WSL2 limitation — mic-only mode)"
      end
      lines.join("\n")
    end

    private

    def check_dependencies!
      missing = []
      missing << "pactl (pulseaudio-utils)" unless command_exists?("pactl")
      missing << "ffmpeg"                    unless command_exists?("ffmpeg")

      unless missing.empty?
        raise "Missing required tools: #{missing.join(", ")}\n" \
              "Install with: sudo apt-get install #{missing.map { |m| m.split.first }.join(" ")}"
      end
    end

    def command_exists?(cmd)
      system("which #{cmd} > /dev/null 2>&1")
    end

    def spawn_ffmpeg(source, output_path, key)
      log_path = File.join(output_dir, "ffmpeg_#{key}.log")
      @ffmpeg_logs[key] = log_path
      spawn(
        "ffmpeg", "-y",
        "-f", "pulse", "-i", source,
        "-ar", SAMPLE_RATE, "-ac", CHANNELS,
        "-codec:a", "libmp3lame", "-b:a", BITRATE,
        output_path,
        out: "/dev/null", err: log_path
      )
    end
  end
end
