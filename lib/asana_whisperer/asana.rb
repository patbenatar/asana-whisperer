require "net/http"
require "uri"
require "json"

module AsanaWhisperer
  class Asana
    BASE_URL = "https://app.asana.com/api/1.0"

    def initialize(access_token)
      @access_token = access_token
    end

    # Parse task GID from any Asana task URL format:
    #   V0: https://app.asana.com/0/{project_gid}/{task_gid}[/f]
    #   V1: https://app.asana.com/1/{workspace_gid}/project/{project_gid}/task/{task_gid}
    def self.parse_task_gid(url)
      # V1 format: /task/{task_gid}
      if (m = url.match(%r{/task/(\d+)}))
        return m[1]
      end

      # V0 format: /0/{project_gid}/{task_gid}
      if (m = url.match(%r{app\.asana\.com/0/\d+/(\d+)}))
        return m[1]
      end

      nil
    end

    def fetch_task(task_gid)
      response = get("/tasks/#{task_gid}", opt_fields: "name,html_notes,notes,permalink_url,projects.name")
      data = parse_response!(response, "fetch task")
      data["data"]
    end

    def prepend_to_task(task_gid, prepend_html, existing_html_notes)
      # Strip outer <body>...</body> from existing content if present
      inner = strip_body_tags(existing_html_notes.to_s)

      divider = inner.empty? ? "" : "\n<hr/>\n"
      new_html = "<body>#{prepend_html}#{divider}#{inner}</body>"

      response = put("/tasks/#{task_gid}", { html_notes: new_html })
      parse_response!(response, "update task")
    end

    private

    def get(path, params = {})
      uri = URI("#{BASE_URL}#{path}")
      unless params.empty?
        uri.query = URI.encode_www_form(params)
      end
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@access_token}"
      request["Accept"]        = "application/json"
      execute(uri, request)
    end

    def put(path, body)
      uri = URI("#{BASE_URL}#{path}")
      request = Net::HTTP::Put.new(uri)
      request["Authorization"] = "Bearer #{@access_token}"
      request["Content-Type"]  = "application/json"
      request["Accept"]        = "application/json"
      request.body = JSON.generate({ data: body })
      execute(uri, request)
    end

    def execute(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
    end

    def parse_response!(response, context)
      unless response.is_a?(Net::HTTPSuccess)
        body = JSON.parse(response.body) rescue { "errors" => [{ "message" => response.body }] }
        messages = body.fetch("errors", []).map { |e| e["message"] }.join("; ")
        raise "Asana API error (#{context}): HTTP #{response.code} — #{messages}"
      end
      JSON.parse(response.body)
    end

    def strip_body_tags(html)
      html.strip
          .sub(/\A\s*<body[^>]*>/i, "")
          .sub(%r{</body>\s*\z}i, "")
          .strip
    end
  end
end
