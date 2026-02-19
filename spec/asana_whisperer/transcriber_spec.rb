require "spec_helper"
require "tempfile"
require "json"

RSpec.describe AsanaWhisperer::Transcriber do
  let(:transcriber) { described_class.new("test_api_key") }

  # ── #mime_type ─────────────────────────────────────────────────────────────

  describe "#mime_type (private)" do
    {
      "audio.mp3"  => "audio/mpeg",
      "audio.wav"  => "audio/wav",
      "audio.mp4"  => "audio/mp4",
      "audio.m4a"  => "audio/mp4",
      "audio.webm" => "audio/webm",
      "audio.ogg"  => "audio/mpeg",   # unknown falls back to mp3
    }.each do |filename, expected_mime|
      it "returns #{expected_mime} for #{filename}" do
        expect(transcriber.send(:mime_type, filename)).to eq(expected_mime)
      end
    end
  end

  # ── #build_multipart_body ─────────────────────────────────────────────────

  describe "#build_multipart_body (private)" do
    let(:audio_file) do
      Tempfile.new(["test", ".mp3"]).tap do |f|
        f.binmode
        f.write("fake audio bytes \x00\x01\x02")
        f.flush
      end
    end

    after { audio_file.close! }

    let(:boundary) { "testboundary123" }
    let(:body) do
      transcriber.send(:build_multipart_body,
        boundary:   boundary,
        fields:     { "model" => "gpt-4o-mini-transcribe", "language" => "en" },
        file_path:  audio_file.path,
        file_field: "file"
      )
    end

    it "includes the boundary markers" do
      expect(body).to include("--#{boundary}")
      expect(body).to include("--#{boundary}--")
    end

    it "includes each text field" do
      expect(body).to include("gpt-4o-mini-transcribe")
      expect(body).to include("language")
      expect(body).to include("en")
    end

    it "includes the file content" do
      expect(body).to include("fake audio bytes")
    end

    it "includes the correct Content-Type for the file" do
      expect(body).to include("Content-Type: audio/mpeg")
    end

    it "includes the filename in the Content-Disposition" do
      expect(body).to include("filename=\"#{File.basename(audio_file.path)}\"")
    end

    it "returns a binary-encoded string so concatenation with audio data never raises" do
      expect(body.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  # ── #transcribe ────────────────────────────────────────────────────────────

  describe "#transcribe" do
    let(:audio_file) do
      Tempfile.new(["rec", ".mp3"]).tap do |f|
        f.binmode
        f.write("x" * 2048)   # above the 1024-byte minimum
        f.flush
      end
    end

    after { audio_file.close! }

    let(:mock_http) { instance_double(Net::HTTP) }

    before { allow(Net::HTTP).to receive(:start).and_yield(mock_http) }

    it "returns the transcript text from the API" do
      response = double("response").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(r).to receive(:body).and_return(JSON.generate({ "text" => "hello world" }))
      end
      allow(mock_http).to receive(:request).and_return(response)

      expect(transcriber.transcribe(audio_file.path)).to eq("hello world")
    end

    it "strips leading/trailing whitespace from the transcript" do
      response = double("response").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(r).to receive(:body).and_return(JSON.generate({ "text" => "  hello  " }))
      end
      allow(mock_http).to receive(:request).and_return(response)

      expect(transcriber.transcribe(audio_file.path)).to eq("hello")
    end

    it "raises on an API error response" do
      response = double("response").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(r).to receive(:code).and_return("401")
        allow(r).to receive(:body).and_return(
          JSON.generate({ "error" => { "message" => "Invalid API key" } })
        )
      end
      allow(mock_http).to receive(:request).and_return(response)

      expect { transcriber.transcribe(audio_file.path) }
        .to raise_error(/Whisper API error.*Invalid API key/)
    end

    it "returns nil for a missing file" do
      expect(transcriber.transcribe("/nonexistent/path/audio.mp3")).to be_nil
    end

    it "returns nil for a file smaller than 1024 bytes" do
      small = Tempfile.new(["tiny", ".mp3"])
      small.write("too small")
      small.flush

      expect(transcriber.transcribe(small.path)).to be_nil
    ensure
      small.close!
    end

    it "sends the Authorization header with the API key" do
      response = double("response").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(r).to receive(:body).and_return(JSON.generate({ "text" => "ok" }))
      end

      expect(mock_http).to receive(:request) do |req|
        expect(req["Authorization"]).to eq("Bearer test_api_key")
        response
      end

      transcriber.transcribe(audio_file.path)
    end
  end
end
