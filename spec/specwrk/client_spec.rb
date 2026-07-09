# frozen_string_literal: true

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
        expect(http).to receive(:finish).ordered.and_call_original
        expect(http).to receive(:start).ordered.and_call_original

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
        expect(http).to receive(:start).exactly(5).times.and_call_original

        expect { subject }.to raise_error(EOFError)
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
    end

    context "when response is error" do
      before do
        stub_request(:post, "#{base_uri}/seed").to_return(status: 500, body: "boom")
      end

      it "raises an UnhandledResponseError" do
        expect { subject }.to raise_error(Specwrk::UnhandledResponseError, /500: boom/)
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
