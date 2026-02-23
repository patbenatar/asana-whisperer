require "net/http"
require "uri"
require "json"
require "securerandom"

module AsanaWhisperer
  class Transcriber
    OPENAI_WHISPER_URL = "https://api.openai.com/v1/audio/transcriptions"
    MAX_SIZE_BYTES     = 24 * 1024 * 1024  # 24 MB safety margin (API limit is 25 MB)

    # Local model support (--local flag):
    #
    #   WHISPER_API_URL — API endpoint (read only in --local mode)
    #                     faster-whisper-server: http://localhost:8000/v1/audio/transcriptions
    #                     LocalAI:               http://localhost:8080/v1/audio/transcriptions
    #   WHISPER_MODEL   — Model name (read only in --local mode, default: "default")
    #                     faster-whisper: Systran/faster-whisper-base, ...medium, ...large-v3
    #                     LocalAI/whisper.cpp: whisper-1, base, medium, large

    def initialize(api_key, api_url: OPENAI_WHISPER_URL, model: "gpt-4o-mini-transcribe")
      @api_key  = api_key
      @api_url  = api_url
      @model    = model
    end

    # Returns transcript text, or nil if the file is missing/too small.
    def transcribe(file_path, language: "en")
      return nil unless File.exist?(file_path) && File.size(file_path) > 1024

      if File.size(file_path) > MAX_SIZE_BYTES
        transcribe_chunked(file_path, language: language)
      else
        call_whisper(file_path, language: language)
      end
    end

    private

    def call_whisper(file_path, language:)
      uri      = URI(@api_url)
      boundary = SecureRandom.hex(16)

      body = build_multipart_body(
        boundary: boundary,
        fields: {
          "model"      => @model,        # OpenAI
          "model_name" => @model,        # faster-whisper-server
          "language"   => language,
        },
        file_path: file_path,
        file_field: "file"
      )

      req = Net::HTTP::Post.new(uri)
      req["Authorization"]  = "Bearer #{@api_key}" if @api_key&.match?(/\S/)
      req["Content-Type"]   = "multipart/form-data; boundary=#{boundary}"
      req["Accept"]         = "application/json"
      req.body              = body

      use_ssl = uri.scheme == "https"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: use_ssl,
                                 read_timeout: 300, open_timeout: 30) do |http|
        http.request(req)
      end

      unless response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body) rescue {}
        raise "Whisper API error: HTTP #{response.code} — " \
              "#{data.dig("error", "message") || response.body[0, 200]}"
      end

      data = JSON.parse(response.body)
      text = data["text"]
      raise "Whisper returned no text. Response: #{data.inspect}" unless text
      text.strip
    end

    # Builds a multipart/form-data body from field hash + one binary file
    def build_multipart_body(boundary:, fields:, file_path:, file_field:)
      parts = []

      fields.each do |name, value|
        parts << "--#{boundary}\r\n" \
                 "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n" \
                 "#{value}\r\n"
      end

      filename = File.basename(file_path)
      mime     = mime_type(file_path)
      file_data = File.binread(file_path)

      parts << "--#{boundary}\r\n" \
               "Content-Disposition: form-data; name=\"#{file_field}\"; filename=\"#{filename}\"\r\n" \
               "Content-Type: #{mime}\r\n\r\n"

      # Force binary encoding for all segments so concatenation with
      # the audio file bytes (ASCII-8BIT) doesn't raise an EncodingError.
      parts.join.b + file_data + "\r\n--#{boundary}--\r\n".b
    end

    def mime_type(path)
      case File.extname(path).downcase
      when ".mp3"  then "audio/mpeg"
      when ".mp4"  then "audio/mp4"
      when ".wav"  then "audio/wav"
      when ".webm" then "audio/webm"
      when ".m4a"  then "audio/mp4"
      else "audio/mpeg"
      end
    end

    # Split large files into 10-minute chunks via ffmpeg, transcribe each
    def transcribe_chunked(file_path, language:)
      require "tmpdir"
      Dir.mktmpdir("asana-transcribe-") do |dir|
        chunk_pattern = File.join(dir, "chunk_%03d.mp3")
        success = system(
          "ffmpeg", "-y", "-i", file_path,
          "-f", "segment", "-segment_time", "600",
          "-codec", "copy",
          chunk_pattern,
          out: "/dev/null", err: "/dev/null"
        )

        raise "Failed to split audio file for chunked transcription" unless success

        chunks = Dir.glob(File.join(dir, "chunk_*.mp3")).sort
        raise "No chunks produced from #{file_path}" if chunks.empty?

        chunks.map { |c| call_whisper(c, language: language) }.join(" ")
      end
    end
  end
end
