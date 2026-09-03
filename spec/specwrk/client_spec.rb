# frozen_string_literal: true

require "openssl"

require "specwrk/client"

RSpec.describe Specwrk::Client do
  let(:base_uri) { "http://localhost:5138" }
  let(:srv_key) { "secret-key" }
  let(:run_id) { "run-123" }
  let(:worker_id) { "specwrk-worker-0-1" }

  let(:headers) do
    {
      "User-Agent" => "Specwrk/#{Specwrk::VERSION}",
      "Authorization" => "Bearer #{srv_key}",
      "X-Specwrk-Run" => run_id,
      "X-Specwrk-Id" => worker_id
    }
  end

  around do |ex|
    previous_net_http = Specwrk.net_http
    Specwrk.net_http = Net::HTTP

    ex.run

    Specwrk.net_http = previous_net_http
  end

  before do
    stub_const("ENV", ENV.to_h.merge(
      "SPECWRK_SRV_URI" => base_uri,
      "SPECWRK_SRV_KEY" => srv_key,
      "SPECWRK_RUN" => run_id,
      "SPECWRK_ID" => worker_id,
      "SPECWRK_NETWORK_RETRIES" => "5"
    ))
  end

  describe ".connect?" do
    subject { described_class.connect? }

    context "when the server is reachable" do
      before do
        stub_request(:get, "#{base_uri}/").to_return(status: 200)
        allow_any_instance_of(Net::HTTP).to receive(:start).and_return(nil)
        allow_any_instance_of(Net::HTTP).to receive(:finish).and_return(nil)
      end

      it { is_expected.to be true }
    end

    context "when the server is not reachable" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      end

      it { is_expected.to be false }
    end

    context "when the handshake fails (e.g. an http/https scheme mismatch)" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(OpenSSL::SSL::SSLError)
      end

      it { is_expected.to be false }
    end

    context "when the TCP connect times out (Net::HTTP's own deadline)" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(Net::OpenTimeout)
      end

      it { is_expected.to be false }
    end

    context "when the TCP connect times out (raw IO::TimeoutError from TCPSocket)" do
      before do
        allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(IO::TimeoutError)
      end

      it { is_expected.to be false }
    end
  end

  describe ".build_http" do
    before do
      stub_const("ENV", ENV.to_h.merge(
        "SPECWRK_SRV_URI" => base_uri,
        "SPECWRK_TIMEOUT" => "42"
      ))
    end

    context "use_ssl" do
      subject { described_class.build_http.use_ssl? }

      context "http" do
        let(:base_uri) { "http://example.com" }

        it { is_expected.to eq(false) }
      end

      context "https" do
        let(:base_uri) { "https://example.com" }

        it { is_expected.to eq(true) }
      end
    end

    context "verify_mode" do
      subject { described_class.build_http.verify_mode }

      context "https URI with SPECWRK_SSL_NO_VERIFY set" do
        let(:base_uri) { "https://example.com" }

        before { stub_const("ENV", ENV.to_h.merge("SPECWRK_SSL_NO_VERIFY" => "1")) }

        it { is_expected.to eq(OpenSSL::SSL::VERIFY_NONE) }
      end

      context "https URI, knob unset" do
        let(:base_uri) { "https://example.com" }

        it { is_expected.to be_nil } # Net::HTTP's default
      end

      # Gated on use_ssl? so plain-http connections never carry a misleading
      # verify_mode.
      context "http URI with SPECWRK_SSL_NO_VERIFY set" do
        let(:base_uri) { "http://example.com" }

        before { stub_const("ENV", ENV.to_h.merge("SPECWRK_SSL_NO_VERIFY" => "1")) }

        it { is_expected.to be_nil }
      end
    end

    context "open_timeout" do
      subject { described_class.build_http.open_timeout }

      it { is_expected.to eq(42) }
    end

    context "read_timeout" do
      subject { described_class.build_http.read_timeout }

      it { is_expected.to eq(42) }
    end
  end

  describe ".wait_for_server!" do
    before do
      stub_const("ENV", ENV.to_h.merge("SPECWRK_TIMEOUT" => "1"))
    end

    it "raises if server is not available before timeout" do
      expect(described_class).to receive(:connect?)
        .and_return(false)
        .at_least(1)

      start_time = Time.now
      attempts = 0

      expect(described_class).to receive(:sleep)
        .and_return(true)
        .at_least(1)

      allow(Time).to receive(:now) do
        attempts += 1
        start_time + (attempts * 0.2) # simulate time progressing 0.2s per attempt
      end

      expect {
        described_class.wait_for_server!
      }.to raise_error(Errno::ECONNREFUSED)
    end

    it "succeeds if server becomes available before timeout" do
      # Fail first 3 times, succeed after
      attempts = 0
      allow(described_class).to receive(:connect?) do
        attempts += 1
        attempts >= 4
      end

      start_time = Time.now

      expect(described_class).to receive(:sleep)
        .and_return(true)
        .at_least(1)

      allow(Time).to receive(:now) do
        start_time + (attempts * 0.2) # simulate time progressing 0.2s per attempt
      end

      expect {
        described_class.wait_for_server!
      }.not_to raise_error
      expect(attempts).to be >= 4
    end
  end

  describe "#worker_status" do
    subject { client.worker_status }

    let(:client) { described_class.new }

    context "not set" do
      it { is_expected.to eq(1) }
    end

    context "server returns a value" do
      before do
        stub_request(:get, "#{base_uri}/heartbeat")
          .with(headers: headers)
          .to_return(status: 200, headers: {"X-Specwrk-Status" => 42})

        client.heartbeat
      end

      it { is_expected.to eq(42) }
    end
  end

  describe "#heartbeat" do
    subject { client.heartbeat }

    let(:client) { described_class.new }

    context "when heartbeat returns 200" do
      before do
        stub_request(:get, "#{base_uri}/heartbeat")
          .with(headers: headers)
          .to_return(status: 200)
      end

      it { is_expected.to be true }
    end

    context "when heartbeat fails" do
      before do
        stub_request(:get, "#{base_uri}/heartbeat").to_return(status: 500)
      end

      it { is_expected.to be false }
    end
  end

  describe "#stats" do
    subject { client.stats }

    let(:client) { described_class.new }

    before do
      stub_request(:post, "#{base_uri}/pop")
        .with(headers: headers)
        .to_return(status: 200, body: "[]")

      stub_request(:get, "#{base_uri}/heartbeat")
        .with(headers: headers)
        .to_return(status: 200)
    end

    it "records call counts and durations per endpoint path" do
      client.fetch_examples
      client.heartbeat
      client.heartbeat

      expect(subject.keys).to contain_exactly("/pop", "/heartbeat")
      expect(subject["/pop"][:calls]).to eq(1)
      expect(subject["/pop"][:duration]).to be_a(Float).and(be >= 0)
      expect(subject["/heartbeat"][:calls]).to eq(2)
    end
  end

  # Teardown only: reopening inside reconnect! put a connect on a path that
  # is not retried, so a connect timeout there escaped make_request. The
  # next request's lazy start reopens the socket inside the retried region.
  describe "#reconnect!" do
    let(:client) { described_class.new }

    it "drops the connection without reopening it, and the next request reconnects lazily" do
      stub_request(:post, "#{base_uri}/pop")
        .with(headers: headers)
        .to_return(status: 200, body: "[]")

      http = client.send(:instance_variable_get, :@http)
      expect(client.fetch_examples).to eq([])

      expect(http).to receive(:finish).ordered.and_call_original
      expect(http).to receive(:start).ordered.and_call_original

      client.send(:reconnect!)
      expect(http).not_to be_started

      expect(client.fetch_examples).to eq([])
    end

    # A transient connect failure must never crash the worker. reconnect! no
    # longer connects at all, so there is no path for one to escape from it.
    [Net::OpenTimeout, IO::TimeoutError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError].each do |error_class|
      context "when opening a connection would raise #{error_class}" do
        before do
          http = client.instance_variable_get(:@http)
          allow(http).to receive(:start).and_raise(error_class)
        end

        it "does not attempt to connect, so nothing can raise" do
          http = client.instance_variable_get(:@http)

          expect { client.send(:reconnect!) }.not_to raise_error
          expect(http).not_to have_received(:start)
        end
      end
    end

    it "recovers on the next request via the retried lazy start when the first re-open fails" do
      http = client.instance_variable_get(:@http)
      raised = false
      allow(http).to receive(:start).and_wrap_original do |original, *args|
        next original.call(*args) if raised

        raised = true
        raise Net::OpenTimeout
      end
      allow(client).to receive(:warn)
      allow(client).to receive(:sleep)

      stub_request(:post, "#{base_uri}/pop")
        .with(headers: headers)
        .to_return(status: 200, body: "[]")

      client.send(:reconnect!)

      expect(client.fetch_examples).to eq([])
      expect(client).to have_received(:warn).once
    end
  end

  # The connection used to open eagerly in #initialize, which meant a TCP
  # connect timeout (IO::TimeoutError) crashed the worker at boot — before
  # wait_for_server! ever ran. Opening lazily on the first request puts
  # wait_for_server!'s patient polling in front of the first real connect.
  describe "lazy connection" do
    it "does not open a connection at construction" do
      expect_any_instance_of(Net::HTTP).not_to receive(:start)

      described_class.new
    end

    it "survives a connect timeout at construction time" do
      allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(IO::TimeoutError)

      expect { described_class.new }.not_to raise_error
    end

    it "retries a connect timeout on first use, then succeeds" do
      stub_request(:post, "#{base_uri}/pop")
        .with(headers: headers)
        .to_return(status: 200, body: "[]")

      client = described_class.new
      http = client.send(:instance_variable_get, :@http)
      allow(http).to receive(:start).and_invoke(
        proc { raise IO::TimeoutError },
        proc { true }
      )

      expect(client).to receive(:warn).once
      expect(client).to receive(:sleep).once

      expect(client.fetch_examples).to eq([])
    end

    it "close is a no-op on a client that never connected" do
      expect { described_class.new.close }.not_to raise_error
    end
  end

  describe "request logging" do
    before do
      stub_request(:post, "#{base_uri}/pop")
        .with(headers: headers)
        .to_return(status: 200, body: "[]")
    end

    it "logs one timestamped line per request when log_requests is on" do
      client = described_class.new(log_requests: true)

      expect($stdout).to receive(:puts)
        .with(a_string_matching(%r{\A\[\d{4}-\d{2}-\d{2}T.+\] .+: POST /pop -> 200 in \d+\.\d\ds\z}))

      client.fetch_examples
    end

    it "stays quiet by default" do
      client = described_class.new

      expect($stdout).not_to receive(:puts)

      client.fetch_examples
    end
  end

  describe "#fetch_examples" do
    subject { client.fetch_examples }

    let(:client) { described_class.new }

    context "when response is 200" do
      let(:examples) { [{id: 1, name: "example"}] }

      before do
        stub_request(:post, "#{base_uri}/pop")
          .with(headers: headers)
          .to_return(status: 200, body: examples.to_json)
      end

      it { is_expected.to eq(examples) }
    end

    context "when response is 204" do
      before do
        stub_request(:post, "#{base_uri}/pop").to_return(status: 204)
      end

      it "raises WaitingForSeedError" do
        expect { subject }.to raise_error(Specwrk::WaitingForSeedError)
      end
    end

    context "when response is 404" do
      before do
        stub_request(:post, "#{base_uri}/pop").to_return(status: 404)
      end

      it "raises NoMoreExamplesError" do
        expect { subject }.to raise_error(Specwrk::NoMoreExamplesError)
      end
    end

    context "when response is unknown" do
      before do
        stub_request(:post, "#{base_uri}/pop").to_return(status: 500, body: "fail")
      end

      it "raises UnhandledResponseError" do
        expect { subject }.to raise_error(Specwrk::UnhandledResponseError, /500: fail/)
      end
    end
  end

  describe "request ids on non-idempotent endpoints" do
    let(:client) { described_class.new }

    it "sends a fresh x-specwrk-request-id per logical /pop call" do
      seen_ids = []
      stub_request(:post, "#{base_uri}/pop")
        .with { |req| seen_ids << req.headers["X-Specwrk-Request-Id"] }
        .to_return(status: 200, body: "[]")

      client.fetch_examples
      client.fetch_examples

      expect(seen_ids.length).to eq(2)
      expect(seen_ids).to all(match(/\A\h{8}-/))
      expect(seen_ids.uniq.length).to eq(2)
    end

    it "reuses the same request id across retries of one logical call, so the server can replay" do
      seen_ids = []
      stub_request(:post, "#{base_uri}/complete_and_pop")
        .with { |req| seen_ids << req.headers["X-Specwrk-Request-Id"] }
        .to_raise(EOFError).then
        .to_return(status: 200, body: "[]")

      allow(client).to receive(:warn)
      allow(client).to receive(:sleep)

      client.complete_and_fetch_examples([{id: 1}])

      expect(seen_ids.length).to eq(2)
      expect(seen_ids).to all(match(/\A\h{8}-/)) # present on every attempt, not just the first
      expect(seen_ids.uniq.length).to eq(1)
    end
  end

  describe "#complete_and_fetch_examples" do
    subject { client.complete_and_fetch_examples(payload) }

    let(:client) { described_class.new }
    let(:payload) { [{id: 1}] }

    context "when response is 200" do
      let(:examples) { [{id: 1, name: "example"}] }

      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_return(status: 200, body: examples.to_json)
      end

      it { is_expected.to eq(examples) }
    end

    context "when response is 204" do
      before do
        stub_request(:post, "#{base_uri}/complete_and_pop").to_return(status: 204)
      end

      it "raises WaitingForSeedError" do
        expect { subject }.to raise_error(Specwrk::WaitingForSeedError)
      end
    end

    context "when response is 404" do
      before do
        stub_request(:post, "#{base_uri}/complete_and_pop").to_return(status: 404)
      end

      it "raises NoMoreExamplesError" do
        expect { subject }.to raise_error(Specwrk::NoMoreExamplesError)
      end
    end

    context "when response is unknown" do
      before do
        stub_request(:post, "#{base_uri}/complete_and_pop").to_return(status: 500, body: "fail")
      end

      it "raises UnhandledResponseError" do
        expect { subject }.to raise_error(Specwrk::UnhandledResponseError, /500: fail/)
      end
    end

    context "when a network timeout happens a couple of times then succeeds" do
      let(:examples) { [{id: 2, name: "retried example"}] }

      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(Net::ReadTimeout).then
          .to_raise(Net::WriteTimeout).then
          .to_return(status: 200, body: examples.to_json)
      end

      it "warns twice and then returns the parsed body, resets the retry count" do
        expect(client).to receive(:warn).twice
        expect(client).to receive(:sleep).exactly(2).times

        expect(subject).to eq(examples)
        expect(client.retry_count).to eq(0)
        expect(client.stats["/complete_and_pop"][:calls]).to eq(3) # 2 failed attempts + the successful one
      end
    end

    context "when a connection-reset error happens once then succeeds" do
      let(:examples) { [{id: 3, name: "reset-recovered example"}] }

      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(Errno::ECONNRESET).then
          .to_return(status: 200, body: examples.to_json)

        allow(client).to receive(:warn)
        allow(client).to receive(:sleep)
      end

      it "counts both attempts in stats" do
        expect(subject).to eq(examples)
        expect(client.stats["/complete_and_pop"][:calls]).to eq(2)
      end
    end

    context "when timeouts persist beyond the retry limit" do
      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(Net::ReadTimeout)
      end

      it "warns four times then re-raises the timeout" do
        expect(client).to receive(:warn).exactly(5).times
        expect(client).to receive(:sleep).exactly(5).times

        expect { subject }.to raise_error(Net::ReadTimeout)
      end
    end

    # Puma (or any server-side idle timeout) can close a keep-alive connection
    # this client is still holding open — e.g. while it sits idle through a
    # multi-minute app preload, or through a long-running bucket. Net::HTTP
    # does not auto-retry a POST on a dead keep-alive socket (only idempotent
    # methods get that), so reusing it surfaces as EOFError/ECONNRESET/EPIPE/
    # IOError rather than a clean refusal, and a bare retry would just hit the
    # same dead socket again.
    context "when the keep-alive connection was closed server-side and the request raises EOFError once, then succeeds" do
      let(:examples) { [{id: 2, name: "reconnected example"}] }

      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(EOFError).then
          .to_return(status: 200, body: examples.to_json)
      end

      it "reconnects (finish then start) before retrying, returns the parsed body, and resets the retry count" do
        http = client.send(:instance_variable_get, :@http)

        expect(client).to receive(:warn).once
        expect(client).to receive(:sleep).once
        expect(http).to receive(:start).ordered.and_call_original # the lazy first open
        expect(http).to receive(:finish).ordered.and_call_original
        expect(http).to receive(:start).ordered.and_call_original # the reconnect

        expect(subject).to eq(examples)
        expect(client.retry_count).to eq(0)
      end
    end

    context "when the connection keeps dying across every retry" do
      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(EOFError)
      end

      it "reconnects and warns each time, then re-raises the original error once retries are exhausted" do
        http = client.send(:instance_variable_get, :@http)

        expect(client).to receive(:warn).exactly(5).times
        expect(client).to receive(:sleep).exactly(5).times
        expect(http).to receive(:finish).exactly(5).times.and_call_original
        expect(http).to receive(:start).exactly(6).times.and_call_original # lazy first open + 5 reconnects

        expect { subject }.to raise_error(EOFError)
      end
    end

    # A TLS keep-alive socket torn down server-side (queue server or its load
    # balancer dropping connections under load) surfaces as
    # OpenSSL::SSL::SSLError "SSL_read: unexpected eof while reading" on the
    # next request — NOT as EOFError/IOError, so the dead-keep-alive rescue
    # above never caught it and the error crashed whole workers mid-run.
    context "when the TLS session dies mid-request once, then succeeds" do
      let(:examples) { [{id: 4, name: "tls-recovered example"}] }

      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading")).then
          .to_return(status: 200, body: examples.to_json)
      end

      it "reconnects (finish then start) before retrying and returns the parsed body" do
        http = client.send(:instance_variable_get, :@http)

        expect(client).to receive(:warn).once
        expect(client).to receive(:sleep).once
        expect(http).to receive(:start).ordered.and_call_original # the lazy first open
        expect(http).to receive(:finish).ordered.and_call_original
        expect(http).to receive(:start).ordered.and_call_original # the reconnect

        expect(subject).to eq(examples)
        expect(client.retry_count).to eq(0)
      end
    end

    context "when the TLS session keeps dying across every retry" do
      before do
        stub_request(:post, "#{base_uri}/complete_and_pop")
          .with(headers: headers)
          .to_raise(OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading"))
      end

      it "reconnects and warns each time, then re-raises once retries are exhausted" do
        expect(client).to receive(:warn).exactly(5).times
        expect(client).to receive(:sleep).exactly(5).times

        expect { subject }.to raise_error(OpenSSL::SSL::SSLError)
      end
    end
  end

  describe "#seed" do
    subject { client.seed(examples, max_retries) }

    let(:client) { described_class.new }
    let(:examples) { [{id: 1}] }
    let(:max_retries) { 5 }

    context "when response is 200" do
      before do
        stub_request(:post, "#{base_uri}/seed")
          .with(headers: headers)
          .to_return(status: 200)
      end

      it { is_expected.to be true }

      it "omits the bucketing override keys so the server's env values stay in charge" do
        subject

        expect(WebMock).to have_requested(:post, "#{base_uri}/seed")
          .with(body: {max_retries: max_retries, examples: examples}.to_json)
      end
    end

    # 0 is a meaningful override (it disables the per-file charge / forces
    # one-file-per-bucket), so provided values — including 0 — go in the
    # payload and absent ones stay out entirely.
    context "with per-run bucketing overrides" do
      subject { client.seed(examples, max_retries, bucket_run_time: 2.5, file_overhead: 0.0) }

      before do
        stub_request(:post, "#{base_uri}/seed").to_return(status: 200)
      end

      it "includes both keys in the payload" do
        expect(subject).to be true

        expect(WebMock).to have_requested(:post, "#{base_uri}/seed")
          .with(body: {max_retries: max_retries, examples: examples, bucket_run_time: 2.5, file_overhead: 0.0}.to_json)
      end
    end

    context "when response is error" do
      before do
        stub_request(:post, "#{base_uri}/seed").to_return(status: 500, body: "boom")
      end

      it "raises an UnhandledResponseError" do
        expect { subject }.to raise_error(Specwrk::UnhandledResponseError, /500: boom/)
      end
    end

    # A seed for a large suite is tens of megabytes of JSON that gzip shrinks
    # ~25x, so anything past the threshold goes out compressed. The server
    # inflates bodies marked Content-Encoding: gzip; one too old to do that
    # would try to parse the compressed bytes, so the server ships first.
    context "when the body is past the compression threshold" do
      let(:examples) do
        Array.new(2_000) { |n| {id: "./spec/a_spec.rb[1:#{n}]", file_path: "./spec/a_spec.rb"} }
      end

      it "gzips the body and marks it, leaving the JSON content type in place" do
        stub_request(:post, "#{base_uri}/seed").to_return(status: 200)

        expect(subject).to be true

        expect(WebMock).to have_requested(:post, "#{base_uri}/seed")
          .with(headers: headers.merge("Content-Encoding" => "gzip", "Content-Type" => "application/json")) { |request|
            request.body.bytesize < described_class::GZIP_MIN_BYTES &&
              JSON.parse(Zlib.gunzip(request.body), symbolize_names: true) == {max_retries: max_retries, examples: examples}
          }
      end
    end

    context "when the body is below the compression threshold" do
      it "sends it plain, as an older server expects" do
        stub_request(:post, "#{base_uri}/seed").to_return(status: 200)

        expect(subject).to be true

        expect(WebMock).to have_requested(:post, "#{base_uri}/seed")
          .with { |request|
            request.headers["Content-Encoding"].nil? &&
              request.body == {max_retries: max_retries, examples: examples}.to_json
          }
      end
    end
  end

  describe "#report" do
    subject { client.report }

    let(:client) { described_class.new }

    context "when response is 200" do
      let(:data) { {foo: "bar"} }

      before do
        stub_request(:get, "#{base_uri}/report")
          .with(headers: headers)
          .to_return(status: 200, body: data.to_json)
      end

      it { is_expected.to eq(data) }
    end

    context "when response is error" do
      before do
        stub_request(:get, "#{base_uri}/report")
          .with(headers: headers)
          .to_return(status: 500, body: "boom")
      end

      it "raises an UnhandledResponseError" do
        expect { subject }.to raise_error(Specwrk::UnhandledResponseError, /500: boom/)
      end
    end
  end
end
