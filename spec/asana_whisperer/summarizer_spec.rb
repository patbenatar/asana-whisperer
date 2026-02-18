require "spec_helper"
require "json"

RSpec.describe AsanaWhisperer::Summarizer do
  let(:summarizer) { described_class.new("test_api_key") }

  # ── #plain_to_html ─────────────────────────────────────────────────────────

  describe "#plain_to_html (private)" do
    def html_for(text)
      summarizer.send(:plain_to_html, text)
    end

    it "wraps ## headings in <h3> tags" do
      expect(html_for("## Requirements")).to include("<h3>Requirements</h3>")
    end

    it "wraps list items in <li> tags inside a <ul>" do
      output = html_for("## Things\n- Item one\n- Item two")
      expect(output).to include("<ul>")
      expect(output).to include("<li>Item one</li>")
      expect(output).to include("<li>Item two</li>")
      expect(output).to include("</ul>")
    end

    it "uses a single <ul> for consecutive list items (no nested lists)" do
      output = html_for("- First\n- Second\n- Third")
      expect(output.scan("<ul>").length).to eq(1)
    end

    it "closes a list before the next heading" do
      output = html_for("- Item\n## Next Section")
      ul_close = output.index("</ul>")
      h3_open  = output.index("<h3>")
      expect(ul_close).to be < h3_open
    end

    it "closes a list before a paragraph" do
      output = html_for("- Item\nSome paragraph text")
      ul_close = output.index("</ul>")
      p_open   = output.index("<p>Some paragraph text</p>")
      expect(ul_close).to be < p_open
    end

    it "escapes & in text content" do
      expect(html_for("- a & b")).to include("a &amp; b")
    end

    it "escapes < and > in text content" do
      expect(html_for("- <tag>")).to include("&lt;tag&gt;")
    end

    it "escapes double quotes" do
      expect(html_for('- say "hello"')).to include("say &quot;hello&quot;")
    end

    it "skips blank lines rather than emitting empty <p> tags" do
      output = html_for("## Section\n\n- Item")
      expect(output).not_to include("<p></p>")
    end

    it "includes a date header" do
      output = html_for("## Requirements\n- x")
      expect(output).to include("via asana-whisperer</em>")
    end

    it "wraps the header in an <h2> tag" do
      output = html_for("## Requirements\n- x")
      expect(output).to include("<h2>Meeting Requirements Summary</h2>")
    end
  end

  # ── #build_prompt ──────────────────────────────────────────────────────────

  describe "#build_prompt (private)" do
    def prompt(**kwargs)
      summarizer.send(:build_prompt, **kwargs)
    end

    let(:base_args) do
      {
        task_name:            "Add search feature",
        existing_description: "",
        your_transcript:      "We need full-text search.",
        others_transcript:    "Should it support filters?"
      }
    end

    it "includes the task name" do
      expect(prompt(**base_args)).to include("Add search feature")
    end

    it "labels your transcript as microphone contributions" do
      expect(prompt(**base_args)).to include("YOUR CONTRIBUTIONS (microphone):")
    end

    it "labels others' transcript as system audio contributions" do
      expect(prompt(**base_args)).to include("OTHERS IN THE MEETING (system audio):")
    end

    it "uses mic-only phrasing when others_transcript is nil" do
      args = base_args.merge(others_transcript: nil)
      expect(prompt(**args)).to include("microphone only")
      expect(prompt(**args)).not_to include("OTHERS IN THE MEETING")
    end

    it "uses mic-only phrasing when others_transcript is blank" do
      args = base_args.merge(others_transcript: "   ")
      expect(prompt(**args)).to include("microphone only")
    end

    it "uses system-audio-only phrasing when your_transcript is nil" do
      args = base_args.merge(your_transcript: nil, others_transcript: "Others spoke here")
      result = prompt(**args)
      expect(result).to include("system audio only")
      expect(result).not_to include("YOUR CONTRIBUTIONS")
    end

    it "uses system-audio-only phrasing when your_transcript is blank" do
      args = base_args.merge(your_transcript: "  ", others_transcript: "Others spoke here")
      expect(prompt(**args)).to include("system audio only")
    end

    it "strips HTML tags from the existing description" do
      args = base_args.merge(existing_description: "<body><h1>Old stuff</h1></body>")
      result = prompt(**args)
      expect(result).to include("Old stuff")
      expect(result).not_to include("<h1>")
    end

    it "shows a placeholder when existing description is empty" do
      expect(prompt(**base_args)).to include("no existing description")
    end

    it "truncates very long existing descriptions to avoid bloating the prompt" do
      long_desc = "word " * 1000
      result = prompt(**base_args.merge(existing_description: long_desc))
      # The truncated section sent to Claude is capped at 2000 chars
      expect(result.length).to be < long_desc.length + 2000
    end
  end

  # ── #summarize ─────────────────────────────────────────────────────────────

  describe "#summarize" do
    let(:mock_http) { instance_double(Net::HTTP) }
    let(:claude_text) do
      "## Requirements\n- Do the thing\n\n## Key Context & Background\n- Context here\n\n## Open Questions\n- None"
    end

    before { allow(Net::HTTP).to receive(:start).and_yield(mock_http) }

    def api_response(text)
      double("response").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(r).to receive(:body).and_return(
          JSON.generate({ "content" => [{ "type" => "text", "text" => text }] })
        )
      end
    end

    it "returns both :plain and :html keys" do
      allow(mock_http).to receive(:request).and_return(api_response(claude_text))

      result = summarizer.summarize(
        task_name:            "Feature X",
        existing_description: "",
        your_transcript:      "We discussed this",
        others_transcript:    "Agreed on approach"
      )

      expect(result).to have_key(:plain)
      expect(result).to have_key(:html)
    end

    it "returns the raw Claude text as :plain" do
      allow(mock_http).to receive(:request).and_return(api_response(claude_text))

      result = summarizer.summarize(
        task_name: "X", existing_description: "",
        your_transcript: "a", others_transcript: "b"
      )

      expect(result[:plain]).to eq(claude_text)
    end

    it "returns valid HTML as :html" do
      allow(mock_http).to receive(:request).and_return(api_response(claude_text))

      result = summarizer.summarize(
        task_name: "X", existing_description: "",
        your_transcript: "a", others_transcript: "b"
      )

      expect(result[:html]).to include("<h3>Requirements</h3>")
      expect(result[:html]).to include("<li>Do the thing</li>")
    end

    it "sends the API key in the x-api-key header" do
      expect(mock_http).to receive(:request) do |req|
        expect(req["x-api-key"]).to eq("test_api_key")
        api_response(claude_text)
      end

      summarizer.summarize(
        task_name: "X", existing_description: "",
        your_transcript: "a", others_transcript: nil
      )
    end

    it "raises on an API error response" do
      error = double("response").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(r).to receive(:code).and_return("429")
        allow(r).to receive(:body).and_return(
          JSON.generate({ "error" => { "message" => "Rate limit exceeded" } })
        )
      end
      allow(mock_http).to receive(:request).and_return(error)

      expect {
        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: nil
        )
      }.to raise_error(/Anthropic API error.*Rate limit exceeded/)
    end
  end
end
