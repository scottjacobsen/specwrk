# frozen_string_literal: true

require "specwrk/worker/progress_formatter"

RSpec.describe Specwrk::Worker::ProgressFormatter do
  before do
    allow(RSpec::Core::Formatters).to receive(:register)
      .with(described_class, :example_started, :example_passed, :example_pending, :example_failed, :dump_failures, :dump_pending)
  end

  let(:instance) { described_class.new(output) }
  let(:output) { StringIO.new }

  let(:example_notification) { instance_double(RSpec::Core::Notifications::ExampleNotification) }
  let(:examples_notification) do
    instance_double RSpec::Core::Notifications::ExamplesNotification,
      failure_notifications: [1],
      fully_formatted_failed_examples: "big fail",
      pending_examples: [1],
      fully_formatted_pending_examples: "a pending"
  end

  describe "#example_started" do
    def notification_for(file)
      instance_double(
        RSpec::Core::Notifications::ExampleNotification,
        example: instance_double(RSpec::Core::Example, metadata: {file_path: file})
      )
    end

    it "prints each spec file once, when the running file changes" do
      instance.example_started(notification_for("./spec/a_spec.rb"))
      instance.example_started(notification_for("./spec/a_spec.rb"))
      instance.example_started(notification_for("./spec/b_spec.rb"))

      expect(output.string).to eq("\n./spec/a_spec.rb\n\n./spec/b_spec.rb\n")
    end
  end

  describe "#example_passed" do
    subject { instance.example_passed(example_notification) }

    it { expect { subject }.to change(output, :string).to(RSpec::Core::Formatters::ConsoleCodes.wrap(".", :success)) }
  end

  describe "#example_pending" do
    subject { instance.example_pending(example_notification) }

    it { expect { subject }.to change(output, :string).to(RSpec::Core::Formatters::ConsoleCodes.wrap("*", :pending)) }
  end

  describe "#example_failed" do
    subject { instance.example_failed(example_notification) }

    it { expect { subject }.to change(output, :string).to(RSpec::Core::Formatters::ConsoleCodes.wrap("F", :failure)) }
  end

  describe "#dump_failures" do
    subject { instance.dump_failures(examples_notification) }

    it { expect { subject }.to change { instance.final_output.tap(&:rewind).read }.to("big fail\n") }
  end

  describe "#dump_pending" do
    subject { instance.dump_pending(examples_notification) }

    it { expect { subject }.to change { instance.final_output.tap(&:rewind).read }.to("a pending\n") }
  end
end
