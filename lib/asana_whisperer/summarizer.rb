require "net/http"
require "uri"
require "json"

module AsanaWhisperer
  class Summarizer
    ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
    MAX_TOKENS        = 4096

    # Local model support (--local flag):
    #
    #   LLM_API_URL   — API endpoint (read only in --local mode)
    #                   Local Ollama: http://localhost:11434/v1/chat/completions
    #   LLM_PROVIDER  — "anthropic" (default) or "openai" (read only in --local mode)
    #   LLM_MODEL     — Model name (read only in --local mode)
    #                   Ollama examples: llama3.2, qwen2.5:7b, mistral

    def initialize(api_key, api_url: ANTHROPIC_API_URL, model: "claude-sonnet-4-6", provider: "anthropic")
      @api_key  = api_key
      @api_url  = api_url
      @model    = model
      @provider = provider
    end

    # Returns { html: String, plain: String }
    def summarize(task_name:, existing_description:, your_transcript:, others_transcript:, mode: :requirements)
      builder = case mode
                when :discovery then :build_discovery_prompt
                when :review    then :build_design_review_prompt
                else                 :build_prompt
                end
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

        You may use these sections — but ONLY include a section if it has real bullet points beneath it:

        "## Requirements" — concrete requirements or decisions from the discussion, written as specific, actionable bullet points (acceptance criteria when possible). Only include items explicitly stated or agreed upon in the transcript.

        "## Key Context & Background" — critical context that does NOT fit as a requirement AND is NOT already in the existing ticket description AND is NOT redundant with the Requirements section. This section is rarely needed.

        OUTPUT RULES:
        1. Every line you output must be a section header ("## ...") or a bullet point ("- ..."). Nothing else. No introductions, no conclusions, no commentary, no notes about omitted sections, no explanations.
        2. A bullet point must contain a specific, concrete piece of information from the transcript. A bullet that says there is nothing to report (e.g. "Nothing new was discussed", "No additional context") is not real content — do not write it.
        3. Do not restate anything already in the ticket description.
        4. If a section would have zero bullet points, do not include its header.
        5. If the discussion produced nothing new at all, output nothing — a completely empty response.
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

        Your task is to surface the key discovery outputs from this conversation. Only include information that was explicitly discussed in the transcript. Do not generate your own questions, conclusions, or inferences.

        You may use these sections — but ONLY include a section if it has real bullet points beneath it:

        "## Decisions" — decisions, agreements, or resolutions the team reached. Only include items where the team clearly settled on an answer or direction.

        "## Open Questions" — questions the team raised but did NOT resolve. Only include questions that participants actually voiced. If the team identified a way to answer a question, put it in Next Steps instead, not here.

        "## Context & Background" — context, constraints, or assumptions surfaced in the conversation that are NOT already in the ticket description.

        "## Next Steps" — concrete actions, research tasks, or follow-ups that participants explicitly proposed. Include owner if mentioned.

        OUTPUT RULES:
        1. Every line you output must be a section header ("## ...") or a bullet point ("- ..."). Nothing else. No introductions, no conclusions, no commentary, no notes about omitted sections, no explanations.
        2. A bullet point must contain a specific, concrete piece of information from the transcript. A bullet that says there is nothing to report (e.g. "Nothing new was discussed", "No relevant context") is not real content — do not write it.
        3. NEVER invent content. Every bullet must trace back to something a participant said.
        4. Do not restate anything already in the ticket description.
        5. If a section would have zero bullet points, do not include its header.
        6. If the discussion produced nothing worth capturing, output nothing — a completely empty response.
      PROMPT
    end

    def build_design_review_prompt(task_name:, existing_description:, your_transcript:, others_transcript:)
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
        You are capturing notes from a design review meeting. The team was reviewing completed design or product work on a ticket to decide whether it is ready to move forward or needs to go back for revision.

        TICKET NAME: #{task_name}

        EXISTING TICKET DESCRIPTION (for context — do not repeat what's already captured here):
        #{desc_section}

        MEETING DISCUSSION:
        #{transcript_section}

        Your task is to capture the outcome of the design review and any feedback that was discussed. Only include information that was explicitly discussed in the transcript. Do not generate your own feedback or inferences.

        You may use these sections — but ONLY include a section if it has real bullet points beneath it:

        "## Outcome" — whether the ticket was accepted and is moving forward, or is being sent back for revision. If sent back, briefly state the core reason why.

        "## Requested Changes" — specific, concrete, actionable changes that must be completed before the ticket can move forward. Only include this section if the ticket is being sent back. Do not list minor suggestions or nice-to-haves.

        "## Context & Background" — new context, constraints, or rationale surfaced in the review that are NOT already in the ticket description.

        OUTPUT RULES:
        1. Every line you output must be a section header ("## ...") or a bullet point ("- ..."). Nothing else. No introductions, no conclusions, no commentary, no notes about omitted sections, no explanations.
        2. A bullet point must contain a specific, concrete piece of information from the transcript. A bullet that says there is nothing to report (e.g. "Nothing new was discussed", "No relevant context") is not real content — do not write it.
        3. NEVER invent content. Every bullet must trace back to something a participant said.
        4. Do not restate anything already in the ticket description.
        5. If a section would have zero bullet points, do not include its header.
        6. If the ticket was accepted with no meaningful feedback, it is fine to output only a single Outcome bullet.
        7. If the discussion produced nothing worth capturing, output nothing — a completely empty response.
      PROMPT
    end

    def call_api(prompt)
      uri = URI(@api_url)
      req = Net::HTTP::Post.new(uri)
      req["content-type"] = "application/json"

      if @provider == "openai"
        # OpenAI-compatible format: Ollama, LM Studio, LocalAI, etc.
        req["Authorization"] = "Bearer #{@api_key || "ollama"}"
        req.body = JSON.generate({
          model:      @model,
          max_tokens: MAX_TOKENS,
          messages:   [{ role: "user", content: prompt }]
        })
      else
        # Anthropic format
        req["x-api-key"]         = @api_key
        req["anthropic-version"] = "2023-06-01"
        req.body = JSON.generate({
          model:      @model,
          max_tokens: MAX_TOKENS,
          messages:   [{ role: "user", content: prompt }]
        })
      end

      use_ssl = uri.scheme == "https"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: use_ssl) { |h| h.request(req) }

      unless response.is_a?(Net::HTTPSuccess)
        body = JSON.parse(response.body) rescue {}
        raise "LLM API error: HTTP #{response.code} — #{body.dig("error", "message") || response.body}"
      end

      data = JSON.parse(response.body)

      if @provider == "openai"
        data.dig("choices", 0, "message", "content") or raise "Unexpected OpenAI response: #{data.inspect}"
      else
        data.dig("content", 0, "text") or raise "Unexpected Anthropic response: #{data.inspect}"
      end
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
