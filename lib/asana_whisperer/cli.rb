require "dotenv/load"
require_relative "audio"
require_relative "asana"
require_relative "transcriber"
require_relative "summarizer"

module AsanaWhisperer
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      args = argv.dup
      mode = args.delete("--discover") || args.delete("-d") ? :discovery : :requirements

      url = args.first&.strip

      if url.nil? || url.empty? || url.start_with?("-")
        abort usage
      end

      validate_env!

      task_gid = Asana.parse_task_gid(url)
      abort "Could not parse a task ID from that URL.\n#{usage}" unless task_gid

      # ── 1. Fetch the Asana ticket ──────────────────────────────────────────
      print "Fetching ticket... "
      asana = Asana.new(ENV["ASANA_ACCESS_TOKEN"])
      task  = asana.fetch_task(task_gid)
      puts "done"
      puts
      puts "  Ticket : #{task["name"]}"
      project_name = task.dig("projects", 0, "name")
      puts "  Project: #{project_name}" if project_name
      puts "  Mode   : #{mode == :discovery ? "Discovery" : "Requirements"}"
      puts

      # ── 2. Detect audio sources ────────────────────────────────────────────
      print "Detecting audio sources... "
      audio = Audio.new
      begin
        audio.detect_sources!
      rescue => e
        abort "\nAudio setup failed: #{e.message}"
      end
      puts "done"
      puts audio.describe_sources
      puts

      unless audio.mic_source
        abort "No microphone source found. Cannot record."
      end

      warn_if_no_monitor(audio)

      # ── 3. Record ──────────────────────────────────────────────────────────
      puts "Recording — press Enter or Ctrl+C to stop.\n\n"

      audio.start_recording!

      stop_requested = false

      # Catch Ctrl+C
      Signal.trap("INT") { stop_requested = true }

      # Also catch Enter keypress (non-blocking thread)
      input_thread = Thread.new do
        $stdin.gets
        stop_requested = true
      end

      # Live timer display
      while !stop_requested
        elapsed = audio.elapsed_seconds
        m, s    = elapsed.divmod(60)
        size_info = audio.files.map do |key, _|
          mb = audio.file_size_mb(key)
          "#{key}: #{mb} MB"
        end.join(" | ")

        print "\r  \e[31m●\e[0m %02d:%02d  %s   " % [m, s, size_info]
        $stdout.flush
        sleep 0.5
      end

      puts "\r\n"
      input_thread.kill rescue nil
      Signal.trap("INT", "DEFAULT")

      # ── 4. Stop recording ──────────────────────────────────────────────────
      print "Stopping recording... "
      audio.stop_recording!
      puts "done"

      mic_size  = audio.file_size_mb(:mic)
      sys_size  = audio.file_size_mb(:monitor)
      elapsed   = audio.elapsed_seconds
      m, s      = elapsed.divmod(60)
      puts "  Duration: %02d:%02d" % [m, s]
      puts "  Mic file: #{mic_size} MB" if mic_size > 0
      puts "  System file: #{sys_size} MB" if sys_size > 0
      puts

      if mic_size < 0.01
        warn_stream_failed(audio, :mic)
      end

      if sys_size < 0.01 && audio.monitor_source
        warn_stream_failed(audio, :monitor)
      end

      if mic_size < 0.01 && sys_size < 0.01
        abort "Both audio streams are empty — nothing to transcribe."
      end

      # ── 5. Transcribe ──────────────────────────────────────────────────────
      transcriber = Transcriber.new(ENV["OPENAI_API_KEY"])

      your_transcript   = nil
      others_transcript = nil

      if mic_size >= 0.01
        print "Transcribing your audio... "
        your_transcript = transcriber.transcribe(audio.files[:mic])
        puts "done"
      end

      if sys_size >= 0.01
        print "Transcribing meeting audio... "
        others_transcript = transcriber.transcribe(audio.files[:monitor])
        puts "done"
      end
      puts

      if your_transcript.to_s.strip.empty? && others_transcript.to_s.strip.empty?
        abort "Transcription produced no text."
      end

      # ── 6. Summarize ──────────────────────────────────────────────────────
      llm_label = ENV["LLM_MODEL"] || (ENV["LLM_API_URL"] ? "local LLM" : "Claude")
      print "Summarizing with #{llm_label}... "
      summarizer = Summarizer.new(ENV["ANTHROPIC_API_KEY"])
      result = summarizer.summarize(
        task_name:            task["name"],
        existing_description: task["html_notes"] || task["notes"],
        your_transcript:      your_transcript,
        others_transcript:    others_transcript,
        mode:                 mode
      )
      puts "done"
      puts

      puts divider
      puts result[:plain]
      puts divider
      puts

      # ── 7. Update Asana ────────────────────────────────────────────────────
      if mode == :discovery
        print "Adding comment to Asana ticket... "
        asana.add_comment(task_gid, result[:html])
      else
        print "Updating Asana ticket... "
        asana.prepend_to_task(task_gid, result[:html], task["html_notes"])
      end
      puts "done"
      puts
      puts "Updated: #{task["permalink_url"] || url}"

    rescue => e
      $stderr.puts "\nError: #{e.message}"
      exit 1
    ensure
      audio&.cleanup!
    end

    private

    def validate_env!
      required = ["ASANA_ACCESS_TOKEN"]
      required << "OPENAI_API_KEY"    unless ENV["WHISPER_API_URL"]&.match?(/\S/)
      required << "ANTHROPIC_API_KEY" unless ENV["LLM_API_URL"]&.match?(/\S/)

      missing = required.reject { |k| ENV[k]&.match?(/\S/) }
      return if missing.empty?

      abort "Missing required environment variables: #{missing.join(", ")}\n" \
            "Copy .env.example to .env and fill in your API keys.\n" \
            "To use local models instead, set WHISPER_API_URL and LLM_API_URL in .env."
    end

    def warn_stream_failed(audio, key)
      label = key == :mic ? "Microphone" : "System audio"
      puts "  Warning: #{label} (#{key == :mic ? audio.mic_source : audio.monitor_source}) recorded nothing."
      err = audio.ffmpeg_error(key)
      if err
        puts "  ffmpeg: #{err.lines.last(3).join("  ").strip}"
      end
      puts "  Continuing with the other stream only."
      puts
    end

    def warn_if_no_monitor(audio)
      return if audio.monitor_available?

      puts "  Note: System audio monitor not available."
      puts "  Only your microphone will be captured (others in the meeting will not be transcribed)."
      puts "  On WSL2, route your audio through a virtual cable on Windows for full capture."
      puts
    end

    def divider
      "─" * 60
    end

    def usage
      <<~USAGE
        Usage: asana-whisperer [--discover] <asana-task-url>

        Options:
          --discover, -d   Discovery mode: surfaces open questions, context, and next
                           steps, then adds a comment to the ticket (default: Requirements
                           mode, which extracts concrete requirements and prepends them to
                           the ticket description)

        Examples:
          asana-whisperer https://app.asana.com/0/123456/789012
          asana-whisperer --discover https://app.asana.com/1/ws/project/123/task/456

        Starts recording your microphone (and system audio if available),
        then on Enter/Ctrl+C transcribes and summarizes the discussion
        into the Asana ticket.

        Required environment variables (set in .env):
          OPENAI_API_KEY       — OpenAI API key (for Whisper transcription)
          ANTHROPIC_API_KEY    — Anthropic API key (for Claude summarization)
          ASANA_ACCESS_TOKEN   — Asana personal access token
      USAGE
    end
  end
end
