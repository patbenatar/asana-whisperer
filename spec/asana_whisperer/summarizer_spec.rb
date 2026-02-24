require "spec_helper"
require "json"

RSpec.describe AsanaWhisperer::Summarizer do
  let(:summarizer) { described_class.new("test_api_key") }

  # ── #plain_to_html ─────────────────────────────────────────────────────────

  describe "#plain_to_html (private)" do
    def html_for(text)
      summarizer.send(:plain_to_html, text)
    end

    it "wraps ## headings in <strong> tags" do
      expect(html_for("## Requirements")).to include("<strong>Requirements</strong>")
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
      ul_close    = output.index("</ul>")
      strong_open = output.index("<strong>")
      expect(ul_close).to be < strong_open
    end

    it "closes a list before a paragraph" do
      output   = html_for("- Item\nSome paragraph text")
      ul_close = output.index("</ul>")
      text_pos = output.index("Some paragraph text")
      expect(ul_close).to be < text_pos
    end

    it "escapes & in text content" do
      expect(html_for("- a & b")).to include("a &amp; b")
    end

    it "escapes < and > in text content" do
      expect(html_for("- <tag>")).to include("&lt;tag&gt;")
    end

    it "does not escape double quotes (not required for Asana HTML)" do
      expect(html_for('- say "hello"')).to include('say "hello"')
    end

    it "skips blank lines rather than emitting empty <p> tags" do
      output = html_for("## Section\n\n- Item")
      expect(output).not_to include("<p></p>")
    end

    it "renders the heading text inside <strong> tags" do
      output = html_for("## Requirements\n- x")
      expect(output).to include("<strong>Requirements</strong>")
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

  # ── #build_discovery_prompt ────────────────────────────────────────────────

  describe "#build_discovery_prompt (private)" do
    def prompt(**kwargs)
      summarizer.send(:build_discovery_prompt, **kwargs)
    end

    let(:base_args) do
      {
        task_name:            "Research caching strategy",
        existing_description: "",
        your_transcript:      "We don't know which layer to cache at.",
        others_transcript:    "Should we use Redis or Memcached?"
      }
    end

    it "includes the task name" do
      expect(prompt(**base_args)).to include("Research caching strategy")
    end

    it "includes Decisions section header" do
      expect(prompt(**base_args)).to include("## Decisions")
    end

    it "includes Open Questions section header" do
      expect(prompt(**base_args)).to include("## Open Questions")
    end

    it "includes Next Steps section header" do
      expect(prompt(**base_args)).to include("## Next Steps")
    end

    it "includes Context & Background section header" do
      expect(prompt(**base_args)).to include("## Context & Background")
    end

    it "does not mention Requirements as the focus" do
      expect(prompt(**base_args)).not_to include("## Requirements")
    end

    it "instructs not to invent content" do
      result = prompt(**base_args)
      expect(result).to include("NEVER invent content")
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

    it "uses system-audio-only phrasing when your_transcript is nil" do
      args = base_args.merge(your_transcript: nil, others_transcript: "Others spoke")
      expect(prompt(**args)).to include("system audio only")
      expect(prompt(**args)).not_to include("YOUR CONTRIBUTIONS")
    end

    it "shows a placeholder when existing description is empty" do
      expect(prompt(**base_args)).to include("no existing description")
    end

    it "strips HTML tags from the existing description" do
      args = base_args.merge(existing_description: "<body><h1>Old context</h1></body>")
      result = prompt(**args)
      expect(result).to include("Old context")
      expect(result).not_to include("<h1>")
    end
  end

  # ── #build_design_review_prompt ───────────────────────────────────────

  describe "#build_design_review_prompt (private)" do
    def prompt(**kwargs)
      summarizer.send(:build_design_review_prompt, **kwargs)
    end

    let(:base_args) do
      {
        task_name:            "Redesign checkout flow",
        existing_description: "",
        your_transcript:      "I think the layout needs more whitespace.",
        others_transcript:    "We should send this back for the spacing issue."
      }
    end

    it "includes the task name" do
      expect(prompt(**base_args)).to include("Redesign checkout flow")
    end

    it "includes Outcome section header" do
      expect(prompt(**base_args)).to include("## Outcome")
    end

    it "includes Requested Changes section header" do
      expect(prompt(**base_args)).to include("## Requested Changes")
    end

    it "includes Context & Background section header" do
      expect(prompt(**base_args)).to include("## Context & Background")
    end

    it "does not mention Requirements or Open Questions sections" do
      result = prompt(**base_args)
      expect(result).not_to include("## Requirements")
      expect(result).not_to include("## Open Questions")
    end

    it "instructs not to invent content" do
      expect(prompt(**base_args)).to include("NEVER invent content")
    end

    it "mentions design review context" do
      expect(prompt(**base_args)).to include("design review")
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

    it "uses system-audio-only phrasing when your_transcript is nil" do
      args = base_args.merge(your_transcript: nil, others_transcript: "Others spoke")
      expect(prompt(**args)).to include("system audio only")
      expect(prompt(**args)).not_to include("YOUR CONTRIBUTIONS")
    end

    it "shows a placeholder when existing description is empty" do
      expect(prompt(**base_args)).to include("no existing description")
    end

    it "strips HTML tags from the existing description" do
      args = base_args.merge(existing_description: "<body><h1>Old design notes</h1></body>")
      result = prompt(**args)
      expect(result).to include("Old design notes")
      expect(result).not_to include("<h1>")
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

      expect(result[:html]).to include("<strong>Requirements</strong>")
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
      }.to raise_error(/LLM API error.*Rate limit exceeded/)
    end

    context "with mode: :requirements (default)" do
      it "uses the requirements prompt (mentions Requirements section)" do
        captured_prompt = nil
        allow(mock_http).to receive(:request) do |req|
          captured_prompt = JSON.parse(req.body).dig("messages", 0, "content")
          api_response(claude_text)
        end

        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b"
        )

        expect(captured_prompt).to include("requirements")
      end

      it "defaults to requirements mode when mode is not specified" do
        captured_prompt = nil
        allow(mock_http).to receive(:request) do |req|
          captured_prompt = JSON.parse(req.body).dig("messages", 0, "content")
          api_response(claude_text)
        end

        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b"
        )

        expect(captured_prompt).to include("requirements")
        expect(captured_prompt).not_to include("Open Questions")
      end
    end

    context "with mode: :discovery" do
      let(:discovery_text) do
        "## Decisions\n- Use Redis for caching\n\n## Open Questions\n- Who owns this?\n\n## Next Steps\n- Set up a spike"
      end

      it "uses the discovery prompt (mentions open questions)" do
        captured_prompt = nil
        allow(mock_http).to receive(:request) do |req|
          captured_prompt = JSON.parse(req.body).dig("messages", 0, "content")
          api_response(discovery_text)
        end

        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :discovery
        )

        expect(captured_prompt).to include("Open Questions")
      end

      it "does not use the requirements prompt when in discovery mode" do
        captured_prompt = nil
        allow(mock_http).to receive(:request) do |req|
          captured_prompt = JSON.parse(req.body).dig("messages", 0, "content")
          api_response(discovery_text)
        end

        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :discovery
        )

        expect(captured_prompt).not_to include("acceptance criteria")
      end

      it "returns both :plain and :html" do
        allow(mock_http).to receive(:request).and_return(api_response(discovery_text))

        result = summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :discovery
        )

        expect(result).to have_key(:plain)
        expect(result).to have_key(:html)
      end

      it "returns the raw Claude text as :plain" do
        allow(mock_http).to receive(:request).and_return(api_response(discovery_text))

        result = summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :discovery
        )

        expect(result[:plain]).to eq(discovery_text)
      end
    end

    context "with mode: :review" do
      let(:design_review_text) do
        "## Outcome\n- Sent back for revision — spacing and hierarchy need rework\n\n## Requested Changes\n- Increase whitespace between sections\n- Revisit the heading hierarchy"
      end

      it "uses the design review prompt (mentions design review)" do
        captured_prompt = nil
        allow(mock_http).to receive(:request) do |req|
          captured_prompt = JSON.parse(req.body).dig("messages", 0, "content")
          api_response(design_review_text)
        end

        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :review
        )

        expect(captured_prompt).to include("design review")
      end

      it "does not use the requirements or discovery prompt" do
        captured_prompt = nil
        allow(mock_http).to receive(:request) do |req|
          captured_prompt = JSON.parse(req.body).dig("messages", 0, "content")
          api_response(design_review_text)
        end

        summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :review
        )

        expect(captured_prompt).not_to include("acceptance criteria")
        expect(captured_prompt).not_to include("Open Questions")
      end

      it "returns both :plain and :html" do
        allow(mock_http).to receive(:request).and_return(api_response(design_review_text))

        result = summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :review
        )

        expect(result).to have_key(:plain)
        expect(result).to have_key(:html)
      end

      it "returns the raw Claude text as :plain" do
        allow(mock_http).to receive(:request).and_return(api_response(design_review_text))

        result = summarizer.summarize(
          task_name: "X", existing_description: "",
          your_transcript: "a", others_transcript: "b",
          mode: :review
        )

        expect(result[:plain]).to eq(design_review_text)
      end
    end
  end
end
