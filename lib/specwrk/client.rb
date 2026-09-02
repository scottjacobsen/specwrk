# frozen_string_literal: true

require "uri"
require "net/http"
require "openssl"
require "json"
require "securerandom"
require "time"
require "zlib"

require "specwrk"

# Some rspec setups might use webmock, which intercepts specwrk server calls
# Let's capture the OG HTTP before that happens
Specwrk.net_http = Net::HTTP

module Specwrk
  class Client
    # POST bodies at least this large go out gzipped (a large seed is tens of
    # MB of JSON that deflates ~25x). The server inflates by Content-Encoding,
    # and one predating that support would JSON.parse compressed bytes — a
    # client this new requires a server at least as new. Deploy server first.
    GZIP_MIN_BYTES = 64 * 1024

    def self.connect?
      http = build_http
      http.start
      http.finish

      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError,
      Net::OpenTimeout, IO::TimeoutError
      # A connect timeout is the same answer as a refused connection: not up
      # yet. wait_for_server! polls this in a loop; raising crashed workers
      # during boot herds.
      false
    end

    def self.build_http
      uri = URI(ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138"))
      Specwrk.net_http.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == "https"
        # Opt-out for self-signed server certs (e.g. a CI-only server)
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl? && ENV["SPECWRK_SSL_NO_VERIFY"]
        http.open_timeout = ENV.fetch("SPECWRK_TIMEOUT", "5").to_i
        http.read_timeout = ENV.fetch("SPECWRK_TIMEOUT", "5").to_i
        http.keep_alive_timeout = 300
      end
    end

    def self.wait_for_server!
      timeout = Time.now + ENV.fetch("SPECWRK_TIMEOUT", "5").to_i
      connected = false

      until connected || Time.now > timeout
        connected = connect?
        sleep 0.1 unless connected
      end

      raise Errno::ECONNREFUSED unless connected
    end

    attr_reader :last_request_at, :retry_count, :worker_status, :stats

    # log_requests: one timestamped line per HTTP attempt. The connection is
    # NOT opened here — an eager connect made a TCP timeout at construction
    # crash the worker before wait_for_server! ever ran; make_request opens
    # it lazily.
    def initialize(log_requests: false)
      @log_requests = log_requests
      @mutex = Mutex.new
      @http = self.class.build_http
      @worker_status = 1
      # Keyed by request path; make_request holds @mutex for the whole
      # attempt loop, so writes here need no extra lock.
      @stats = Hash.new { |h, path| h[path] = {calls: 0, duration: 0.0} }
    end

    def close
      @mutex.synchronize { @http.finish if @http.started? }
    end

    # For long idle gaps the caller knows about (e.g. an app preload): the
    # server drops the keep-alive socket well before then, and reconnecting
    # up front beats paying a logged EOFError retry on the next request.
    def reconnect
      @mutex.synchronize { reconnect! }
    end

    def heartbeat
      response = get "/heartbeat"

      response.code == "200"
    end

    def report
      response = get "/report"

      if response.code == "200"
        JSON.parse(response.body, symbolize_names: true)
      else
        raise UnhandledResponseError.new("#{response.code}: #{response.body}")
      end
    end

    def shutdown
      response = delete "/shutdown"

      if response.code == "200"
        response.body
      else
        raise UnhandledResponseError.new("#{response.code}: #{response.body}")
      end
    end

    def fetch_examples
      response = post "/pop", headers: idempotency_headers

      case response.code
      when "200"
        JSON.parse(response.body, symbolize_names: true)
      when "204"
        raise WaitingForSeedError
      when "404"
        raise NoMoreExamplesError
      when "410"
        raise CompletedAllExamplesError
      else
        raise UnhandledResponseError.new("#{response.code}: #{response.body}")
      end
    end

    def complete_and_fetch_examples(examples)
      response = post "/complete_and_pop", body: examples.to_json, headers: idempotency_headers

      case response.code
      when "200"
        JSON.parse(response.body, symbolize_names: true)
      when "204"
        raise WaitingForSeedError
      when "404"
        raise NoMoreExamplesError
      when "410"
        raise CompletedAllExamplesError
      else
        raise UnhandledResponseError.new("#{response.code}: #{response.body}")
      end
    end

    # The bucketing overrides go in the payload only when provided: 0 is a
    # meaningful value for both (disables the per-file charge / forces
    # one-file-per-bucket), so absent must stay distinguishable from 0 — an
    # absent key leaves the server's env-configured behavior untouched.
    def seed(examples, max_retries, bucket_run_time: nil, file_overhead: nil)
      body = {max_retries: max_retries, examples: examples}
      body[:bucket_run_time] = bucket_run_time unless bucket_run_time.nil?
      body[:file_overhead] = file_overhead unless file_overhead.nil?

      response = post "/seed", body: body.to_json

      (response.code == "200") ? true : raise(UnhandledResponseError.new("#{response.code}: #{response.body}"))
    end

    private

    # /pop and /complete_and_pop are non-idempotent, yet make_request retries
    # them when a response is lost mid-flight. A fresh id per LOGICAL call,
    # reused across its retries, lets the server replay its recorded response
    # instead of processing the request twice.
    def idempotency_headers
      default_headers.merge("x-specwrk-request-id" => SecureRandom.uuid)
    end

    def get(path, headers: default_headers, body: nil)
      request = Specwrk.net_http::Get.new(path, headers)
      request.body = body if body

      make_request(request)
    end

    def post(path, headers: default_headers, body: nil)
      body, headers = maybe_gzip(body, headers)

      request = Specwrk.net_http::Post.new(path, headers)
      request.body = body if body

      make_request(request)
    end

    def put(path, headers: default_headers, body: nil)
      request = Specwrk.net_http::Put.new(path, headers)
      request.body = body if body

      make_request(request)
    end

    def delete(path, headers: default_headers, body: nil)
      request = Specwrk.net_http::Delete.new(path, headers)
      request.body = body if body

      make_request(request)
    end

    # Non-mutating: default_headers is memoized and shared, so the gzip
    # marker goes on a copy. Retries re-send the already-compressed body.
    def maybe_gzip(body, headers)
      return [body, headers] if body.nil? || body.bytesize < GZIP_MIN_BYTES

      [Zlib.gzip(body), headers.merge("Content-Encoding" => "gzip")]
    end

    # The retry loop lives INSIDE @mutex.synchronize so a reconnect can never
    # race another thread's request on this client: @http is torn down and
    # rebuilt while still exclusively held.
    def make_request(request)
      @mutex.synchronize do
        # `retry` re-enters here, so each attempt gets its own start time
        attempt_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_request_at = Time.now
        # Explicit rather than letting Net::HTTP#request auto-start, which
        # uses the block form and closes the socket again after one request —
        # silently disabling keep-alive.
        @http.start unless @http.started?
        @http.request(request).tap do |response|
          @retry_count = 0
          record_attempt(request.path, attempt_started_at)
          log_attempt(request, response.code, attempt_started_at)

          @worker_status = response["x-specwrk-status"].to_i if response["x-specwrk-status"]
        end
      rescue Net::ReadTimeout, Net::WriteTimeout, Net::OpenTimeout, IO::TimeoutError => e
        # The open-timeout pair comes from the lazy @http.start above; no
        # reconnect needed. `ensure` does not run on `retry`, so each rescue
        # records its own attempt.
        record_attempt(request.path, attempt_started_at)
        log_attempt(request, e.class, attempt_started_at)
        retry_or_raise!(e)
        retry
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError, OpenSSL::SSL::SSLError => e
        # A server-side idle timeout kills a keep-alive socket undetected;
        # Net::HTTP only auto-retries idempotent methods, so a POST surfaces
        # one of these instead of a clean refusal. On TLS the death arrives
        # as OpenSSL::SSL::SSLError, not an IOError subclass. Reconnect so
        # the retry isn't doomed to the same dead socket.
        record_attempt(request.path, attempt_started_at)
        log_attempt(request, e.class, attempt_started_at)
        retry_or_raise!(e)
        reconnect!
        retry
      end
    end

    def record_attempt(path, started_at)
      entry = @stats[path]
      entry[:calls] += 1
      entry[:duration] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    end

    # Logged per attempt, so a timing-out server shows N slow attempts rather
    # than one opaque gap.
    def log_attempt(request, outcome, started_at)
      return unless @log_requests

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      $stdout.puts format("[%s] %s: %s %s -> %s in %.2fs",
        Time.now.utc.iso8601, ENV.fetch("SPECWRK_ID", "specwrk-client"),
        request.method, request.path, outcome, duration)
      $stdout.flush
    end

    def retry_or_raise!(e)
      @retry_count ||= 0

      raise e if @retry_count == ENV["SPECWRK_NETWORK_RETRIES"].to_i
      @retry_count += 1

      warn e
      sleep @retry_count
    end

    def reconnect!
      @http.finish
    rescue
      nil
    ensure
      @http.start
    end

    def default_headers
      @default_headers ||= {}.tap do |h|
        h["User-Agent"] = "Specwrk/#{VERSION}"
        h["Authorization"] = "Bearer #{ENV["SPECWRK_SRV_KEY"]}" if ENV["SPECWRK_SRV_KEY"]
        h["X-Specwrk-Id"] = ENV.fetch("SPECWRK_ID", "specwrk-client")
        h["X-Specwrk-Run"] = ENV["SPECWRK_RUN"] if ENV["SPECWRK_RUN"]
        h["Content-Type"] = "application/json"
      end
    end
  end
end
