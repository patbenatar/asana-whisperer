require "net/http"
require "uri"
require "json"

module AsanaWhisperer
  class Summarizer
    ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
    MODEL             = "claude-sonnet-4-6"
    MAX_TOKENS        = 4096

    def initialize(api_key)
      @api_key = api_key
    end

    # Returns { html: String, plain: String }
    def summarize(task_name:, existing_description:, your_transcript:, others_transcript:)
      prompt = build_prompt(
        task_name:            task_name,
        existing_description: existing_description,
        your_transcript:      your_transcript,
        others_transcript:    others_transcript
      )

      response = call_api(prompt)
      plain = response.strip

      { html: plain_to_html(plain), plain: plain }
    end

    private

    def build_prompt(task_name:, existing_description:, your_transcript:, others_transcript:)
      desc_section = existing_description.to_s.empty? ?
        "(no existing description)" :
        existing_description.gsub(/<[^>]+>/, " ").squeeze(" ").strip[0, 2000]

      has_your   = your_transcript   && !your_transcript.strip.empty?
      has_others = others_transcript && !others_transcript.strip.empty?

      transcript_section = if has_your && has_others
        <<~TEXT
          YOUR CONTRIBUTIONS (microphone):
          #{your_transcript.strip}

          OTHERS IN THE MEETING (system audio):
          #{others_transcript.strip}
        TEXT
      elsif has_your
        <<~TEXT
          MEETING TRANSCRIPT (microphone only — system audio was not captured):
          #{your_transcript.strip}
        TEXT
      else
        <<~TEXT
          MEETING TRANSCRIPT (system audio only — microphone was not captured):
          #{others_transcript.strip}
        TEXT
      end

      <<~PROMPT
        You are analyzing a transcript from an engineering planning meeting. The team was reviewing a ticket and clarifying its requirements.

        TICKET NAME: #{task_name}

        EXISTING TICKET DESCRIPTION:
        #{desc_section}

        MEETING DISCUSSION:
        #{transcript_section}

        Your task is to extract the final, agreed-upon outcome of this discussion. Ignore tangents, small talk, and anything not directly relevant to the ticket.

        Produce a clear, structured summary in plain text using this exact format:

        ## Requirements
        - [Each concrete, agreed-upon requirement as a bullet point]
        - [Be specific and actionable — write them as acceptance criteria when possible]

        ## Key Context & Background
        - [Important context, constraints, edge cases, or technical considerations raised]
        - [Decisions made and the reasoning behind them]

        ## Open Questions
        - [Any unresolved questions or follow-up items, or write "None" if everything was resolved]

        Keep requirements crisp and unambiguous. If something was discussed but not agreed upon, put it in Open Questions. Do not pad with filler.
      PROMPT
    end

    def call_api(prompt)
      uri = URI(ANTHROPIC_API_URL)
      req = Net::HTTP::Post.new(uri)
      req["x-api-key"]         = @api_key
      req["anthropic-version"] = "2023-06-01"
      req["content-type"]      = "application/json"
      req.body = JSON.generate({
        model:      MODEL,
        max_tokens: MAX_TOKENS,
        messages: [{ role: "user", content: prompt }]
      })

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }

      unless response.is_a?(Net::HTTPSuccess)
        body = JSON.parse(response.body) rescue {}
        raise "Anthropic API error: HTTP #{response.code} — #{body.dig("error", "message") || response.body}"
      end

      data = JSON.parse(response.body)
      data.dig("content", 0, "text") or raise "Unexpected Anthropic response: #{data.inspect}"
    end

    # Convert the plain-text markdown-like output into Asana-compatible HTML
    def plain_to_html(text)
      date_str = Time.now.strftime("%B %-d, %Y at %-I:%M %p")
      lines    = text.strip.lines.map(&:rstrip)
      html     = []
      in_list  = false

      html << "<h2>Meeting Requirements Summary</h2>"
      html << "<p><em>Captured #{date_str} via asana-whisperer</em></p>"

      lines.each do |line|
        if line.start_with?("## ")
          if in_list
            html << "</ul>"
            in_list = false
          end
          html << "<h3>#{escape_html(line[3..].strip)}</h3>"
        elsif line.start_with?("- ")
          unless in_list
            html << "<ul>"
            in_list = true
          end
          html << "<li>#{escape_html(line[2..].strip)}</li>"
        else
          if in_list
            html << "</ul>"
            in_list = false
          end
          html << "<p>#{escape_html(line)}</p>" unless line.empty?
        end
      end

      html << "</ul>" if in_list
      html.join("\n")
    end

    def escape_html(str)
      str.gsub("&", "&amp;")
         .gsub("<", "&lt;")
         .gsub(">", "&gt;")
         .gsub('"', "&quot;")
    end
  end
end
