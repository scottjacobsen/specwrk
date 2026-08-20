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
    # POST bodies at least this large go out gzipped. The seed for a large
    # suite is tens of megabytes of JSON that deflates ~25x, so the fraction
    # of a second it costs to compress buys back most of the upload; below
    # the threshold there is no transfer worth the CPU on either end.
    #
    # The server inflates any body carrying Content-Encoding: gzip, and one
    # that predates that support would try to JSON.parse the compressed
    # bytes — so a client this new REQUIRES a server at least as new. Deploy
    # the server first.
    GZIP_MIN_BYTES = 64 * 1024

    def self.connect?
      http = build_http
      http.start
      http.finish

      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError
      false
    end

    def self.build_http
      uri = URI(ENV.fetch("SPECWRK_SRV_URI", "http://localhost:5138"))
      Specwrk.net_http.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == "https"
        # Self-signed server certs (e.g. a local/CI-only server): skip
        # verification rather than failing every connection. Gated on
        # use_ssl? so a plain-http connection never carries a misleading
        # verify_mode.
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

    # log_requests: emit one timestamped line per HTTP attempt (method, path,
    # response code, duration). On for a worker's data client so CI output
    # shows exactly when the server was called and what it cost; off for the
    # heartbeat client, which would otherwise add a line every ~10s.
    def initialize(log_requests: false)
      @log_requests = log_requests
      @mutex = Mutex.new
      @http = self.class.build_http
      @http.start
      @worker_status = 1
      # Per-instance, keyed by request path ("/pop" etc — paths ARE the
      # endpoint names). make_request already holds @mutex for the whole
      # attempt loop, so writes here are lock-free-safe.
      @stats = Hash.new { |h, path| h[path] = {calls: 0, duration: 0.0} }
    end

    def close
      @mutex.synchronize { @http.finish }
    end

    # For long idle gaps the caller knows about (e.g. a minutes-long app
    # preload): the server drops the keep-alive socket well before then, so
    # the next request would pay a logged EOFError retry. Reconnecting up
    # front keeps that noise out of the output.
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

    def seed(examples, max_retries)
      response = post "/seed", body: {max_retries: max_retries, examples: examples}.to_json

      (response.code == "200") ? true : raise(UnhandledResponseError.new("#{response.code}: #{response.body}"))
    end

    private

    # /pop and /complete_and_pop are non-idempotent (one request both records
    # results and hands out the next bucket), yet make_request retries them
    # when a response is lost mid-flight. A fresh id per LOGICAL call — reused
    # verbatim across that call's retries, since the Net::HTTP request object
    # is built once — lets the server recognize a duplicate and replay its
    # recorded response instead of processing the request twice.
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

    # Non-mutating on both arguments: default_headers is memoized and shared
    # by every request this client makes, so the gzip marker has to go on a
    # copy. Compressing here, before the request object is built, also means
    # make_request's retries re-send the already-compressed body rather than
    # deflating it again per attempt.
    def maybe_gzip(body, headers)
      return [body, headers] if body.nil? || body.bytesize < GZIP_MIN_BYTES

      [Zlib.gzip(body), headers.merge("Content-Encoding" => "gzip")]
    end

    # The retry loop lives INSIDE @mutex.synchronize (unlike a plain rescue on
    # the method, which would release the mutex between attempts) so a
    # reconnect can never race another thread's request on this same client:
    # @http gets torn down and rebuilt while still exclusively held.
    def make_request(request)
      @mutex.synchronize do
        # Re-stamped on every retry: `retry` re-enters right here, at the top
        # of the block, so each attempt gets its own start time.
        attempt_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_request_at = Time.now
        @http.request(request).tap do |response|
          @retry_count = 0
          record_attempt(request.path, attempt_started_at)
          log_attempt(request, response.code, attempt_started_at)

          @worker_status = response["x-specwrk-status"].to_i if response["x-specwrk-status"]
        end
      rescue Net::ReadTimeout, Net::WriteTimeout => e
        # `ensure` does not run on `retry`, so record explicitly here rather
        # than relying on an ensure to cover every attempt.
        record_attempt(request.path, attempt_started_at)
        log_attempt(request, e.class, attempt_started_at)
        retry_or_raise!(e)
        retry
      rescue Errno::ECONNRESET, Errno::EPIPE, IOError => e
        # A keep-alive connection Puma (or another server-side idle timeout)
        # closed while this client held it open goes undetected until the next
        # request tries to reuse it: Net::HTTP only auto-retries idempotent
        # methods on a dead keep-alive socket, so a POST surfaces one of these
        # (IOError covers EOFError, a subclass) instead of a clean refusal.
        # Reconnect before retrying so the retry isn't doomed to hit the same
        # dead socket again.
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

    # Retries log one line each (outcome is the exception class), so a
    # timing-out server shows up as N slow attempts rather than one opaque
    # multi-second gap in the worker's output.
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
