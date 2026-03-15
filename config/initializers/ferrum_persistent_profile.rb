# frozen_string_literal: true

# Monkey-patch Ferrum to support persistent Chrome profile directories.
#
# By default, Ferrum creates a fresh temp directory for every browser instance
# and deletes it when the browser quits. This means cookies, localStorage,
# and sessionStorage are lost between browser restarts.
#
# This patch lets scrapers pass `persistent_user_data_dir` in browser_options.
# When present, Chrome uses that directory instead of a temp one, and it is
# NOT deleted on quit — just like closing and reopening a real browser.
#
# Usage:
#   Ferrum::Browser.new(browser_options: {
#     "user-data-dir": "/path/to/profile",
#     ...
#   }, persistent_user_data_dir: true)
#
# Production impact: NONE unless a scraper explicitly opts in by passing
# `persistent_user_data_dir: true`. All existing scrapers are unaffected
# because they don't pass this option — they continue to use Ferrum's default
# temp directory behavior.
#
# This is critical for suppliers with 2FA (US Foods, PPO) where we can't
# re-login without user interaction. The persistent profile lets us restart
# the browser (freeing memory) while keeping the authenticated session.

Rails.application.config.after_initialize do
  next unless defined?(Ferrum::Browser::Process)

  # Fix Ferrum bug: DEFAULT_OPTIONS is frozen but merge_default tries to
  # call .delete on it when incognito: false. Patch merge_default to dup first.
  if defined?(Ferrum::Browser::Options::Chrome)
    Ferrum::Browser::Options::Chrome.class_eval do
      def merge_default(flags, options)
        defaults = except("headless", "disable-gpu") if options.headless == false
        defaults ||= self.class::DEFAULT_OPTIONS.dup
        defaults.delete("no-startup-window") if options.incognito == false
        defaults = defaults.merge("disable-gpu" => nil) if Ferrum::Utils::Platform.windows?
        defaults = defaults.merge("use-angle" => "metal") if Ferrum::Utils::Platform.mac_arm?
        defaults.merge(flags)
      end
    end
  end

  Ferrum::Browser::Process.class_eval do
    # Save original initialize
    alias_method :original_initialize, :initialize

    def initialize(options)
      # Check if the caller wants a persistent profile
      persistent_dir = options.browser_options[:"user-data-dir"] ||
                       options.browser_options["user-data-dir"]

      if persistent_dir && options.to_h[:persistent_user_data_dir]
        # Use the caller's directory — don't create a temp one
        @pid = @xvfb = nil
        @persistent_profile = true

        if options.ws_url || options.url
          response = parse_json_version(options.ws_url || options.url)
          self.ws_url = options.ws_url || response&.[]("webSocketDebuggerUrl")
          return
        end

        @logger = options.logger
        @process_timeout = options.process_timeout
        @env = Hash(options.env)

        FileUtils.mkdir_p(persistent_dir)
        @user_data_dir = persistent_dir
        @command = Ferrum::Browser::Command.build(options, persistent_dir)
      else
        @persistent_profile = false
        original_initialize(options)
      end
    end

    # Save original stop
    alias_method :original_stop, :stop

    def stop
      if @persistent_profile
        # Kill Chrome but DON'T delete the profile directory
        if @pid
          kill(@pid)
          kill(@xvfb.pid) if @xvfb&.pid
          @pid = nil
        end
        ObjectSpace.undefine_finalizer(self)
      else
        original_stop
      end
    end
  end
end
