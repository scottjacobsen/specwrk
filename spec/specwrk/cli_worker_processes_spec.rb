# frozen_string_literal: true

require "fileutils"

require "specwrk/cli"

RSpec.describe Specwrk::CLI::WorkerProcesses do
  let(:instance) { Class.new { include Specwrk::CLI::WorkerProcesses }.new }

  describe "#start_workers and #drain_outputs" do
    let(:envs) { [] }

    before do
      allow(instance).to receive(:worker_count).and_return(10)
      allow(Process).to receive(:spawn) { |env, *| envs.push(env).length }
    end

    it "hands every worker the same SPECWRK_FINAL_DIR" do
      instance.start_workers

      dirs = envs.map { |env| env.fetch("SPECWRK_FINAL_DIR") }.uniq
      expect(dirs.length).to eq(1)
      expect(File.directory?(dirs.first)).to be(true)
    ensure
      dir = envs.first&.fetch("SPECWRK_FINAL_DIR", nil)
      FileUtils.rm_rf(dir) if dir
    end

    # Numeric worker order, not lexical: worker 10 prints after worker 2.
    it "prints the logs in worker order, skips workers that wrote none, and removes the directory" do
      instance.start_workers
      dir = envs.first.fetch("SPECWRK_FINAL_DIR")
      File.write(File.join(dir, "final-10.log"), "ten\n")
      File.write(File.join(dir, "final-2.log"), "two\n")
      File.write(File.join(dir, "final-1.log"), "one\n")

      expect { instance.drain_outputs }.to output("one\ntwo\nten\n").to_stdout
      expect(File.exist?(dir)).to be(false)
    end
  end

  describe "#worker_env_for" do
    it "leaves the first worker's TEST_ENV_NUMBER blank, parallel_tests-style" do
      expect(instance.worker_env_for(1)).to include("TEST_ENV_NUMBER" => "")
    end

    it "numbers the remaining workers from 2" do
      expect(instance.worker_env_for(2)).to include("TEST_ENV_NUMBER" => "2")
      expect(instance.worker_env_for(3)).to include("TEST_ENV_NUMBER" => "3")
    end
  end
end
