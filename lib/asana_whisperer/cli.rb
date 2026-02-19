require "dotenv/load"
require "stringio"
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
      args  = argv.dup
      mode  = args.delete("--discover") || args.delete("-d") ? :discovery : :requirements
      local = args.delete("--local")    || args.delete("-l")
      url   = args.first&.strip

      if url && !url.empty? && !url.start_with?("-")
        run_once(url, mode: mode, local: local)
      else
        run_interactive(mode: mode, local: local)
      end
    end

    private

    # ── One-and-done mode ─────────────────────────────────────────────────────
    # Launched with a URL: record once, update the ticket, then exit.

    def run_once(url, mode:, local:)
      validate_env!(local: local)

      task_gid = Asana.parse_task_gid(url)
      abort "Could not parse a task ID from that URL.\n#{usage}" unless task_gid

      audio = nil
      begin
        # ── 1. Fetch the Asana ticket ────────────────────────────────────────
        print "Fetching ticket... "
        asana = Asana.new(ENV["ASANA_ACCESS_TOKEN"])
        task  = asana.fetch_task(task_gid)
        puts "done"
        puts
        puts "  Ticket : #{task["name"]}"
        project_name = task.dig("projects", 0, "name")
        puts "  Project: #{project_name}" if project_name
        puts "  Mode   : #{mode == :discovery ? "Discovery" : "Requirements"}"
        puts "  Backend: #{local ? "local" : "cloud"}"
        puts

        # ── 2. Detect audio sources ──────────────────────────────────────────
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

        # ── 3. Record ────────────────────────────────────────────────────────
        puts "Recording — press Enter or Ctrl+C to stop.\n\n"
        audio.start_recording!
        record_loop!(audio)

        # ── 4. Stop recording ────────────────────────────────────────────────
        print "Stopping recording... "
        audio.stop_recording!
        puts "done"
        print_recording_stats(audio)

        if audio.file_size_mb(:mic) < 0.01 && audio.file_size_mb(:monitor) < 0.01
          abort "Both audio streams are empty — nothing to transcribe."
        end

        # ── 5-7. Transcribe, summarize, update ───────────────────────────────
        transcribe_and_update(task_gid: task_gid, task: task, audio: audio,
                              mode: mode, local: local)
      rescue => e
        $stderr.puts "\nError: #{e.message}"
        exit 1
      ensure
        audio&.cleanup!
      end
    end

    # ── Interactive mode ──────────────────────────────────────────────────────
    # Launched without a URL: prompt for tickets in a loop. Each recording is
    # handed off to a background thread for transcription + ticket update while
    # the user can immediately start a new recording. On exit, waits for any
    # in-flight background work to finish before quitting.

    def run_interactive(mode:, local:)
      validate_env!(local: local)

      # ── 1. Detect audio sources once ────────────────────────────────────────
      print "Detecting audio sources... "
      audio_probe = Audio.new
      begin
        audio_probe.detect_sources!
      rescue => e
        abort "\nAudio setup failed: #{e.message}"
      end
      mic_source     = audio_probe.mic_source
      monitor_source = audio_probe.monitor_source
      sources_desc   = audio_probe.describe_sources
      audio_probe.cleanup!

      unless mic_source
        abort "No microphone source found. Cannot record."
      end

      puts "done"
      puts sources_desc
      puts

      unless monitor_source
        puts "  Note: System audio monitor not available — mic-only mode."
        puts "  On WSL2, route your audio through a virtual cable on Windows for full capture."
        puts
      end

      bg_tasks = []  # [{thread:, buffer:, label:}]

      loop do
        # Print buffered output from any completed background tasks before prompting.
        flush_completed_tasks(bg_tasks)

        print "Enter Asana ticket URL (or 'done' to exit): "
        $stdout.flush
        input = $stdin.gets&.strip
        break if input.nil? || %w[done exit quit].include?(input.downcase)
        next  if input.empty?

        task_gid = Asana.parse_task_gid(input)
        unless task_gid
          puts "  Could not parse a task ID from that URL. Please try again."
          next
        end

        print "Fetching ticket... "
        $stdout.flush
        asana = Asana.new(ENV["ASANA_ACCESS_TOKEN"])
        begin
          task = asana.fetch_task(task_gid)
        rescue => e
          puts "\n  Error: #{e.message}"
          next
        end
        puts "done"
        puts
        puts "  Ticket : #{task["name"]}"
        project_name = task.dig("projects", 0, "name")
        puts "  Project: #{project_name}" if project_name
        puts "  Mode   : #{mode == :discovery ? "Discovery" : "Requirements"}"
        puts

        # Fresh audio session reusing the already-detected source names.
        audio = Audio.new(mic_source: mic_source, monitor_source: monitor_source)

        puts "Recording — press Enter or Ctrl+C to stop.\n\n"
        audio.start_recording!
        record_loop!(audio)

        print "Stopping recording... "
        audio.stop_recording!
        puts "done"
        print_recording_stats(audio)

        # Capture locals for the background thread (avoid closure surprises).
        bg_task_gid = task_gid
        bg_task     = task
        bg_audio    = audio
        bg_label    = task["name"]
        buffer      = StringIO.new

        t = Thread.new do
          begin
            buffer.puts
            buffer.puts "─── #{bg_label} " + "─" * [2, 58 - bg_label.length].max
            transcribe_and_update(task_gid: bg_task_gid, task: bg_task,
                                  audio: bg_audio, mode: mode, local: local,
                                  out: buffer)
          rescue => e
            buffer.puts "\nError: #{e.message}"
          ensure
            bg_audio.cleanup!
          end
        end

        bg_tasks << { thread: t, buffer: buffer, label: bg_label }
      end

      # Wait for any still-running background tasks before exiting.
      unless bg_tasks.empty?
        active = bg_tasks.select { |bg| bg[:thread].alive? }
        if active.any?
          n = active.length
          puts "\nWaiting for #{n} pending " \
               "transcription#{n == 1 ? "" : "s"} and ticket " \
               "update#{n == 1 ? "" : "s"}..."
        end
        bg_tasks.each do |bg|
          bg[:thread].join
          flush_buffer(bg[:buffer])
        end
      end

    rescue => e
      $stderr.puts "\nError: #{e.message}"
      exit 1
    end

    # ── Shared recording helpers ──────────────────────────────────────────────

    def record_loop!(audio)
      stop_requested = false
      Signal.trap("INT") { stop_requested = true }
      input_thread = Thread.new { $stdin.gets; stop_requested = true }

      while !stop_requested
        elapsed   = audio.elapsed_seconds
        m, s      = elapsed.divmod(60)
        size_info = audio.files.map { |key, _| "#{key}: #{audio.file_size_mb(key)} MB" }.join(" | ")
        print "\r  \e[31m●\e[0m %02d:%02d  %s   " % [m, s, size_info]
        $stdout.flush
        sleep 0.5
      end

      puts "\r\n"
      input_thread.kill rescue nil
      Signal.trap("INT", "DEFAULT")
    end

    def print_recording_stats(audio)
      mic_size = audio.file_size_mb(:mic)
      sys_size = audio.file_size_mb(:monitor)
      m, s     = audio.elapsed_seconds.divmod(60)
      puts "  Duration: %02d:%02d" % [m, s]
      puts "  Mic file: #{mic_size} MB"    if mic_size > 0
      puts "  System file: #{sys_size} MB" if sys_size > 0
      puts
    end

    # ── Transcription / summarization / ticket update ─────────────────────────
    # Accepts an `out:` IO so this can run in a background thread writing to a
    # StringIO buffer without interleaving with the main thread's output.

    def transcribe_and_update(task_gid:, task:, audio:, mode:, local:, out: $stdout)
      asana    = Asana.new(ENV["ASANA_ACCESS_TOKEN"])
      mic_size = audio.file_size_mb(:mic)
      sys_size = audio.file_size_mb(:monitor)

      warn_stream_failed(audio, :mic,     out: out) if mic_size < 0.01
      warn_stream_failed(audio, :monitor, out: out) if sys_size < 0.01 && audio.monitor_source

      if mic_size < 0.01 && sys_size < 0.01
        out.puts "Both audio streams are empty — nothing to transcribe."
        return
      end

      # ── Transcribe ──────────────────────────────────────────────────────────
      transcriber       = Transcriber.new(ENV["OPENAI_API_KEY"])
      your_transcript   = nil
      others_transcript = nil

      if mic_size >= 0.01
        out.print "Transcribing your audio... "
        your_transcript = transcriber.transcribe(audio.files[:mic])
        out.puts "done"
      end

      if sys_size >= 0.01
        out.print "Transcribing meeting audio... "
        others_transcript = transcriber.transcribe(audio.files[:monitor])
        out.puts "done"
      end
      out.puts

      if your_transcript.to_s.strip.empty? && others_transcript.to_s.strip.empty?
        out.puts "Transcription produced no text."
        return
      end

      # ── Summarize ────────────────────────────────────────────────────────────
      llm_label = ENV["LLM_MODEL"] || (ENV["LLM_API_URL"] ? "local LLM" : "Claude")
      out.print "Summarizing with #{llm_label}... "
      summarizer = Summarizer.new(ENV["ANTHROPIC_API_KEY"])
      result = summarizer.summarize(
        task_name:            task["name"],
        existing_description: task["html_notes"] || task["notes"],
        your_transcript:      your_transcript,
        others_transcript:    others_transcript,
        mode:                 mode
      )
      out.puts "done"
      out.puts

      out.puts divider
      out.puts result[:plain]
      out.puts divider
      out.puts

      # ── Update Asana ──────────────────────────────────────────────────────────
      if mode == :discovery
        out.print "Adding comment to Asana ticket... "
        asana.add_comment(task_gid, result[:html])
      else
        out.print "Updating Asana ticket... "
        asana.prepend_to_task(task_gid, result[:html], task["html_notes"])
      end
      out.puts "done"
      out.puts
      out.puts "Updated: #{task["permalink_url"]}"
    end

    # ── Background-task output helpers ────────────────────────────────────────

    def flush_completed_tasks(bg_tasks)
      completed, pending = bg_tasks.partition { |bg| !bg[:thread].alive? }
      completed.each { |bg| flush_buffer(bg[:buffer]) }
      bg_tasks.replace(pending)
    end

    def flush_buffer(buffer)
      content = buffer.string
      return if content.strip.empty?
      $stdout.print(content)
      $stdout.flush
    end

    # ── Existing private helpers ──────────────────────────────────────────────

    def validate_env!(local:)
      if local
        required = %w[ASANA_ACCESS_TOKEN WHISPER_API_URL LLM_API_URL]
        missing  = required.reject { |k| ENV[k]&.match?(/\S/) }
        return if missing.empty?

        abort "Missing environment variables required for --local mode: #{missing.join(", ")}\n" \
              "Set these in .env — see README for local model setup."
      else
        required = %w[ASANA_ACCESS_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY]
        missing  = required.reject { |k| ENV[k]&.match?(/\S/) }
        return if missing.empty?

        abort "Missing required environment variables: #{missing.join(", ")}\n" \
              "Copy .env.example to .env and fill in your API keys.\n" \
              "To use local models instead, pass --local (and set WHISPER_API_URL and LLM_API_URL in .env)."
      end
    end

    def warn_stream_failed(audio, key, out: $stdout)
      label = key == :mic ? "Microphone" : "System audio"
      source = key == :mic ? audio.mic_source : audio.monitor_source
      out.puts "  Warning: #{label} (#{source}) recorded nothing."
      err = audio.ffmpeg_error(key)
      out.puts "  ffmpeg: #{err.lines.last(3).join("  ").strip}" if err
      out.puts "  Continuing with the other stream only."
      out.puts
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
        Usage: asana-whisperer [--discover] [--local] [<asana-task-url>]

        When launched without a URL, enters interactive mode: prompts for an Asana
        ticket URL, records, then immediately asks for the next URL while the prior
        recording is transcribed and the ticket updated in the background. Type
        'done' (or press Ctrl+D) when finished; the tool waits for any in-flight
        work to complete before exiting.

        When launched with a URL, records once and exits (one-and-done mode).

        Options:
          --discover, -d   Discovery mode: surfaces open questions, context, and next
                           steps, then adds a comment to the ticket (default: Requirements
                           mode, which extracts concrete requirements and prepends them to
                           the ticket description)
          --local, -l      Use local models instead of cloud APIs (requires Ollama and
                           faster-whisper-server to be running). No API keys needed.
                           Model defaults can be overridden via WHISPER_MODEL / LLM_MODEL
                           in .env.

        Examples:
          asana-whisperer
          asana-whisperer https://app.asana.com/0/123456/789012
          asana-whisperer --discover https://app.asana.com/1/ws/project/123/task/456
          asana-whisperer --local https://app.asana.com/0/123456/789012
          asana-whisperer --local --discover https://app.asana.com/0/123456/789012

        Starts recording your microphone (and system audio if available),
        then on Enter/Ctrl+C transcribes and summarizes the discussion
        into the Asana ticket.

        Required environment variables (set in .env):
          OPENAI_API_KEY       — OpenAI API key (for Whisper transcription; not needed with --local)
          ANTHROPIC_API_KEY    — Anthropic API key (for Claude summarization; not needed with --local)
          ASANA_ACCESS_TOKEN   — Asana personal access token
      USAGE
    end
  end
end
