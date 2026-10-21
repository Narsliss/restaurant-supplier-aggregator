# frozen_string_literal: true

require 'net/http'
require 'socket'

module DemoMode
  # Nothing leaves the demo server. Any HTTP request (Net::HTTP, so Faraday
  # too), any raw TCP connection to a non-loopback host, and any headless
  # browser launch raises Blocked. Blocked is a SocketError, so code that
  # already copes with a network outage copes with this the same way.
  #
  # The simulator means no supplier code should get this far; the wall is the
  # backstop for a path we missed.
  module NetworkWall
    class Blocked < SocketError; end

    LOOPBACK = %w[localhost 127.0.0.1 ::1].freeze

    def self.install!
      Net::HTTP.prepend(HttpGuard) unless Net::HTTP <= HttpGuard
      TCPSocket.prepend(SocketGuard) unless TCPSocket <= SocketGuard
      Ferrum::Browser.prepend(BrowserGuard) if defined?(Ferrum::Browser) && !(Ferrum::Browser <= BrowserGuard)
    end

    def self.refuse!(what)
      Rails.logger&.warn "[DemoMode] Blocked outbound #{what}"
      raise Blocked, "Demo mode: outbound #{what} blocked"
    end

    def self.loopback?(host)
      host = host.to_s
      LOOPBACK.include?(host) || host.start_with?('127.')
    end

    module HttpGuard
      private

      def connect
        NetworkWall.refuse!("HTTP to #{address}") if DemoMode.enabled?
        super
      end
    end

    module SocketGuard
      def initialize(remote_host = nil, *args, **kwargs)
        if DemoMode.enabled? && !NetworkWall.loopback?(remote_host)
          NetworkWall.refuse!("connection to #{remote_host}")
        end
        super
      end
    end

    module BrowserGuard
      def initialize(*args, **kwargs)
        NetworkWall.refuse!('browser launch') if DemoMode.enabled?
        super
      end
    end
  end
end
