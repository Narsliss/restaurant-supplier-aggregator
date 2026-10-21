# frozen_string_literal: true

require_relative 'demo_spec_helper'
require 'socket'

RSpec.describe DemoMode::NetworkWall do
  # A loopback port nothing listens on: reaching it proves a connection was
  # attempted, without touching the network.
  let(:closed_port) do
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  context 'with demo mode on' do
    include_context 'demo mode on'

    it 'refuses HTTP to any host before connecting' do
      http = Net::HTTP.new('order.usfoods.com', 443)
      expect { http.send(:connect) }.to raise_error(described_class::Blocked, /order\.usfoods\.com/)
    end

    it 'refuses raw connections to non-loopback hosts' do
      expect { TCPSocket.new('api.groq.com', 443) }.to raise_error(described_class::Blocked)
    end

    it 'still lets loopback sockets through' do
      expect { TCPSocket.new('127.0.0.1', closed_port) }.to raise_error(Errno::ECONNREFUSED)
    end

    it 'refuses to launch a browser' do
      expect { Ferrum::Browser.new(headless: true) }.to raise_error(described_class::Blocked)
    end

    it 'is a SocketError, so Faraday reports it as a connection failure' do
      expect(described_class::Blocked.ancestors).to include(SocketError)
      # Let the request reach the wall instead of stopping at VCR/WebMock.
      VCR.turned_off(ignore_cassettes: true) do
        WebMock.allow_net_connect!
        conn = Faraday.new(url: 'https://api.groq.com')
        expect { conn.get('/') }.to raise_error(Faraday::ConnectionFailed, /blocked/)
      end
    ensure
      WebMock.disable_net_connect!(allow_localhost: true)
    end
  end

  context 'with demo mode off' do
    it 'passes HTTP through untouched' do
      http = Net::HTTP.new('127.0.0.1', closed_port)
      expect { http.send(:connect) }.to raise_error(Errno::ECONNREFUSED)
    end

    it 'passes sockets through untouched' do
      expect { TCPSocket.new('127.0.0.1', closed_port) }.to raise_error(Errno::ECONNREFUSED)
    end
  end
end
