class ApiRateLimitHeaders
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    data = env.dig("rack.attack.throttle_data", "requests per IP")
    if env["PATH_INFO"].start_with?("/api/") && data
      limit = data[:limit]
      remaining = [ limit - data[:count], 0 ].max
      reset = data[:period] - data[:epoch_time] % data[:period]
      headers["ratelimit-limit"] = limit.to_s
      headers["ratelimit-remaining"] = remaining.to_s
      headers["ratelimit-reset"] = reset.to_s
      headers["ratelimit-policy"] = %Q("requests-per-ip";q=#{limit};w=#{data[:period]})
      headers["ratelimit"] = %Q("requests-per-ip";r=#{remaining};t=#{reset})
      headers["retry-after"] = reset.to_s if status == 429
      headers["cache-control"] = "private, no-store"
    end
    [ status, headers, body ]
  end
end
