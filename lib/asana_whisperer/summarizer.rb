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
    def summarize(task_name:, existing_description:, your_transcript:, others_transcript:, mode: :requirements)
      builder = mode == :discovery ? :build_discovery_prompt : :build_prompt
      prompt = send(builder,
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

        EXISTING TICKET DESCRIPTION (for reference only — do not repeat what's already captured here):
        #{desc_section}

        MEETING DISCUSSION:
        #{transcript_section}

        Your task is to extract only the NEW requirements and decisions from the meeting discussion. Focus entirely on what was said in the transcript, not on restating what's already in the ticket description.

        Produce a clear, structured summary in plain text using this exact format:

        ## Requirements
        - [Each concrete requirement or decision from the discussion as a bullet point]
        - [Be specific and actionable — write them as acceptance criteria when possible]
        - [Only include requirements explicitly stated or agreed upon in the transcript]

        ## Key Context & Background
        - [OMIT THIS SECTION ENTIRELY unless there is critical context that: (1) does NOT fit as a requirement, (2) is NOT already in the existing ticket description, AND (3) is NOT redundant with anything in the Requirements section above]
        - [This section is rarely needed — most discussions produce only requirements]

        IMPORTANT: Keep the output minimal. Do not pad with filler. Do not restate anything already in the ticket or in the Requirements section. If the transcript is unclear or garbled, skip those parts. Omit the Key Context section if it would be redundant.
      PROMPT
    end

    def build_discovery_prompt(task_name:, existing_description:, your_transcript:, others_transcript:)
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
        You are capturing notes from a product discovery conversation. The team was exploring a ticket, discussing open questions, unknowns, and what needs to be figured out before work can proceed.

        TICKET NAME: #{task_name}

        EXISTING TICKET DESCRIPTION (for context — do not repeat what's already captured here):
        #{desc_section}

        MEETING DISCUSSION:
        #{transcript_section}

        Your task is to surface the key discovery outputs from this conversation. Focus on what was explored and what remains uncertain — not on definitive conclusions or implementation details.

        Produce a concise summary in plain text using this exact format. Omit any section that has nothing meaningful to add:

        ## Open Questions
        - [Unresolved questions where no clear next step was identified]
        - ONLY include a question here if there is no obvious action to answer it

        ## Context & Background
        - [Relevant context, constraints, or assumptions surfaced in the conversation]
        - [Dependencies or external factors that shape this work]

        ## Next Steps
        - [Concrete actions, research tasks, or conversations that need to happen — include owner if mentioned]

        CRITICAL DEDUPLICATION RULE: A question and its corresponding action are the same item — never list both. If the discussion produced a clear next step to answer a question (e.g. "ask a stakeholder whether X is true"), put it only under Next Steps and omit it from Open Questions entirely. Only put something under Open Questions if there is genuinely no known next step to resolve it.

        IMPORTANT: Keep output concise. Do not invent conclusions that were not stated. Do not restate anything already in the ticket description. Skip any section that has no meaningful content from the transcript.
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
    # Note: Asana does NOT support <p>, <br>, or <hr> tags - use newlines instead
    def plain_to_html(text)
      lines    = text.strip.lines.map(&:rstrip)
      html     = []
      in_list  = false

      lines.each do |line|
        if line.start_with?("## ")
          if in_list
            html << "</ul>"
            in_list = false
          end
          html << "<strong>#{escape_html(line[3..].strip)}</strong>"
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
          html << escape_html(line) unless line.empty?
        end
      end

      html << "</ul>" if in_list
      html.join("\n")
    end

    def escape_html(str)
      # Ensure valid UTF-8 and strip control characters (except newlines/tabs)
      sanitized = str.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
                     .gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")

      # Escape HTML entities (only the essential ones for text content)
      sanitized.gsub("&", "&amp;")
               .gsub("<", "&lt;")
               .gsub(">", "&gt;")
    end
  end
end
