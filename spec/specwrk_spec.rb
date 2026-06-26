# frozen_string_literal: true

RSpec.describe Specwrk do
  it "has a version number" do
    expect(Specwrk::VERSION).not_to be nil
  end

  describe ".example_file_key" do
    it "extracts the spec file from a bracketed rerun id" do
      example = {id: "./spec/a_spec.rb[1:2:1]", file_path: "./spec/support/shared_examples.rb"}

      expect(described_class.example_file_key(example)).to eq("./spec/a_spec.rb")
    end

    it "extracts the spec file from a file:line style id" do
      expect(described_class.example_file_key({id: "a_spec.rb:12", file_path: "a_spec.rb"})).to eq("a_spec.rb")
    end

    it "falls back to file_path when there is no id" do
      expect(described_class.example_file_key({file_path: "a_spec.rb"})).to eq("a_spec.rb")
    end
  end

  describe ".wait_for_pids_exit" do
    subject { described_class.wait_for_pids_exit(pids) }

    let(:pids) { [pid1, pid2] }

    let(:pid1) do
      fork do
        sleep 0.1
        exit 0
      end
    end

    let(:pid2) do
      fork do
        sleep 0.2
        exit 42
      end
    end

    context "returns exit statuses for all PIDs" do
      let(:pids) { [pid1, pid2] }

      it { is_expected.to eq(pid1 => 0, pid2 => 42) }
    end

    context "handles Errno::ECHILD when a PID has already been reaped" do
      before { Process.wait(pid1) } # Causes Errno::ECHILD to raise

      it { is_expected.to eq(pid1 => 1, pid2 => 42) }
    end
  end

  describe "a test that only passes on the second retry on the same instance (assume max retries > 0)" do
    it "should succeed on the 2nd run" do
      file = File.join(Dir.tmpdir, "specwrk.retry")

      count = if File.exist?(file)
        JSON.parse(File.read(file))
      else
        0
      end

      File.write(file, JSON.generate(count + 1))
      if count.zero? && ENV.fetch("SPECWRK_SRV_URI", "").include?("localhost") && ENV["SPECWRK_FORKED"]
        expect(true).to eq(false)
      else
        expect(true).to eq(true)
        FileUtils.rm_rf(file)
      end
    end
  end
end
