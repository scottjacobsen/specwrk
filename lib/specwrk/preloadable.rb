# frozen_string_literal: true

module Specwrk
  # Boot the application (e.g. Rails) once in a long-lived parent process so
  # every child forked from it inherits a fully-booted app whose load-time
  # registrations (model callbacks, subscribers, constants, RSpec config) have
  # run exactly once. SPECWRK_PRELOAD names the file to require, e.g. the app's
  # spec/rails_helper.
  module Preloadable
    # Returns true when a preload file was required, false when SPECWRK_PRELOAD
    # is unset and the app will therefore boot lazily inside each child.
    def preload_app!
      preload = ENV["SPECWRK_PRELOAD"].to_s
      return false if preload.empty?

      # Put the conventional RSpec load paths in place (mirrors `rspec -Ilib
      # -Ispec`) so the preloaded helper and its own requires (e.g. rails_helper's
      # `require "spec_helper"`) resolve the same way a normal rspec run would.
      ["lib", "spec", File.dirname(preload)].each do |dir|
        path = File.expand_path(dir)
        $LOAD_PATH.unshift(path) if File.directory?(path) && !$LOAD_PATH.include?(path)
      end

      require preload

      true
    end
  end
end
