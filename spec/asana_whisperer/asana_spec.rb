require "spec_helper"
require "json"

RSpec.describe AsanaWhisperer::Asana do
  # ── .parse_task_gid ───────────────────────────────────────────────────────

  describe ".parse_task_gid" do
    it "parses a V0 URL" do
      expect(described_class.parse_task_gid("https://app.asana.com/0/111/444555"))
        .to eq("444555")
    end

    it "parses a V0 URL with the /f focus suffix" do
      expect(described_class.parse_task_gid("https://app.asana.com/0/111/444555/f"))
        .to eq("444555")
    end

    it "parses a V1 URL" do
      expect(described_class.parse_task_gid(
        "https://app.asana.com/1/workspace/project/123/task/789"
      )).to eq("789")
    end

    it "parses a V1 URL with a query string" do
      expect(described_class.parse_task_gid(
        "https://app.asana.com/1/ws/project/123/task/456?focus=true"
      )).to eq("456")
    end

    it "returns nil for a URL with no recognisable task ID" do
      expect(described_class.parse_task_gid("https://example.com/no/task/here")).to be_nil
    end

    it "returns nil for an arbitrary string" do
      expect(described_class.parse_task_gid("not a url")).to be_nil
    end
  end

  # ── HTTP helpers ───────────────────────────────────────────────────────────

  let(:client) { described_class.new("test_token") }
  let(:mock_http) { instance_double(Net::HTTP) }

  def success_response(body_hash)
    double("response").tap do |r|
      allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(r).to receive(:body).and_return(JSON.generate(body_hash))
    end
  end

  def error_response(code, message)
    double("response").tap do |r|
      allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(r).to receive(:code).and_return(code.to_s)
      allow(r).to receive(:body).and_return(
        JSON.generate({ "errors" => [{ "message" => message }] })
      )
    end
  end

  before { allow(Net::HTTP).to receive(:start).and_yield(mock_http) }

  # ── #fetch_task ────────────────────────────────────────────────────────────

  describe "#fetch_task" do
    it "returns the task data hash" do
      task = { "gid" => "123", "name" => "My Task", "html_notes" => "<body><p>hi</p></body>" }
      allow(mock_http).to receive(:request).and_return(success_response({ "data" => task }))

      result = client.fetch_task("123")
      expect(result["name"]).to eq("My Task")
      expect(result["html_notes"]).to eq("<body><p>hi</p></body>")
    end

    it "raises an informative error on HTTP failure" do
      allow(mock_http).to receive(:request).and_return(error_response(404, "Task not found"))

      expect { client.fetch_task("999") }
        .to raise_error(/Asana API error.*Task not found/)
    end
  end

  # ── #add_comment ───────────────────────────────────────────────────────────

  describe "#add_comment" do
    let(:ok) { success_response({ "data" => { "gid" => "story-1" } }) }

    it "posts to the task stories endpoint" do
      allow(mock_http).to receive(:request) do |req|
        expect(req.path).to include("/tasks/123/stories")
        ok
      end

      client.add_comment("123", "<strong>Discovery</strong>")
    end

    it "sends the comment as html_text wrapped in a body tag" do
      allow(mock_http).to receive(:request) do |req|
        html_text = JSON.parse(req.body).dig("data", "html_text")
        expect(html_text).to eq("<body><strong>Discovery</strong></body>")
        ok
      end

      client.add_comment("123", "<strong>Discovery</strong>")
    end

    it "uses the POST method" do
      allow(mock_http).to receive(:request) do |req|
        expect(req).to be_a(Net::HTTP::Post)
        ok
      end

      client.add_comment("123", "Some text")
    end

    it "raises on HTTP failure" do
      allow(mock_http).to receive(:request)
        .and_return(error_response(403, "Forbidden"))

      expect { client.add_comment("123", "text") }
        .to raise_error(/Asana API error.*Forbidden/)
    end
  end

  # ── #prepend_to_task ───────────────────────────────────────────────────────

  describe "#prepend_to_task" do
    let(:ok) { success_response({ "data" => { "gid" => "123" } }) }

    it "wraps the combined content in a single <body> tag" do
      allow(mock_http).to receive(:request) do |req|
        html = JSON.parse(req.body).dig("data", "html_notes")
        expect(html.scan("<body>").length).to eq(1)
        expect(html.scan("</body>").length).to eq(1)
        ok
      end

      client.prepend_to_task("123", "<h2>New</h2>", "<body><p>Old</p></body>")
    end

    it "places the new content before the existing content" do
      allow(mock_http).to receive(:request) do |req|
        html = JSON.parse(req.body).dig("data", "html_notes")
        expect(html.index("<h2>New</h2>")).to be < html.index("<p>Old</p>")
        ok
      end

      client.prepend_to_task("123", "<h2>New</h2>", "<body><p>Old</p></body>")
    end

    it "adds a text divider between new and existing content" do
      allow(mock_http).to receive(:request) do |req|
        html = JSON.parse(req.body).dig("data", "html_notes")
        expect(html).to include("────────────────────────────────────────")
        ok
      end

      client.prepend_to_task("123", "<h2>New</h2>", "<body><p>Old</p></body>")
    end

    it "omits the divider when there is no existing content" do
      allow(mock_http).to receive(:request) do |req|
        html = JSON.parse(req.body).dig("data", "html_notes")
        expect(html).not_to include("<hr/>")
        ok
      end

      client.prepend_to_task("123", "<h2>New</h2>", "")
    end

    it "omits the divider when existing content is nil" do
      allow(mock_http).to receive(:request) do |req|
        html = JSON.parse(req.body).dig("data", "html_notes")
        expect(html).not_to include("<hr/>")
        ok
      end

      client.prepend_to_task("123", "<h2>New</h2>", nil)
    end

    it "strips <body> wrapper from existing notes before combining" do
      allow(mock_http).to receive(:request) do |req|
        html = JSON.parse(req.body).dig("data", "html_notes")
        # Inner content preserved, but no double-wrapping
        expect(html).to include("<p>Old</p>")
        expect(html).not_to include("<body><body>")
        ok
      end

      client.prepend_to_task("123", "<h2>New</h2>", "<body><p>Old</p></body>")
    end

    it "raises on HTTP failure" do
      allow(mock_http).to receive(:request)
        .and_return(error_response(403, "Forbidden"))

      expect { client.prepend_to_task("123", "<h2>x</h2>", "") }
        .to raise_error(/Asana API error.*Forbidden/)
    end
  end
end
