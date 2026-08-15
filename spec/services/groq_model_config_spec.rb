require 'rails_helper'

# Guards the Groq migration off the decommissioned llama-3.3-70b-versatile
# (retired 2026-08-16) onto openai/gpt-oss-120b.
#
# gpt-oss is a REASONING model: reasoning tokens are billed against the
# completion budget before any content is emitted. Verified against the live
# API — with the previous 50-token ceiling the response came back
# finish_reason "length" with an EMPTY content string, so every AI match
# silently returned nil while looking healthy in the logs. These specs assert
# the outgoing request body, because that is the thing that broke.
RSpec.describe 'Groq model configuration' do
  GROQ_ENDPOINT = 'https://api.groq.com/openai/v1/chat/completions'.freeze

  # Minimum completion budget that leaves room for reasoning tokens plus a
  # short answer. Live-verified: 50 was consumed entirely by reasoning.
  MIN_SAFE_BUDGET = 256

  def stub_groq(content: '2', status: 200, headers: {})
    stub_request(:post, GROQ_ENDPOINT).to_return(
      status: status,
      headers: { 'Content-Type' => 'application/json' }.merge(headers),
      body: {
        choices: [{ message: { content: content, role: 'assistant' }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 }
      }.to_json
    )
  end

  def last_request_body
    body = nil
    WebMock::RequestRegistry.instance.requested_signatures.each { |sig, _| body = sig.body }
    JSON.parse(body)
  end

  describe 'model constants' do
    it 'no service still points at the decommissioned Llama model' do
      constants = {
        'AiProductMatcherService' => AiProductMatcherService::MODEL,
        'CatalogSearchService' => CatalogSearchService::MODEL,
        'IncrementalProductMatcherService' => IncrementalProductMatcherService::MODEL,
        'AiProductGrouper' => AiProductGrouper::MODEL,
        'PdfParsingService' => PdfParsingService::MODEL,
        'MenuPlannerService' => MenuPlannerService::MENU_MODEL
      }

      expect(constants.values).to all(eq('openai/gpt-oss-120b'))
      expect(constants.values.join).not_to include('llama')
    end
  end

  # The three matchers plus the grouper share an identical call_groq shape.
  {
    'AiProductMatcherService' => -> { AiProductMatcherService.new(nil) },
    'CatalogSearchService' => -> { CatalogSearchService.new(nil) },
    'IncrementalProductMatcherService' => -> { IncrementalProductMatcherService.new(nil) },
    'AiProductGrouper' => -> { AiProductGrouper.new }
  }.each do |service_name, builder|
    describe service_name do
      let(:service) { builder.call }

      before { allow(ENV).to receive(:[]).and_call_original }

      it 'requests the replacement model' do
        stub_groq
        service.send(:call_groq, 'test prompt')
        expect(last_request_body['model']).to eq('openai/gpt-oss-120b')
      end

      it 'leaves enough completion budget for reasoning tokens plus an answer' do
        stub_groq
        service.send(:call_groq, 'test prompt')
        budget = last_request_body['max_tokens']
        expect(budget).to be >= MIN_SAFE_BUDGET,
                          "max_tokens=#{budget} is too small for a reasoning model; " \
                          'reasoning consumes the budget and content comes back empty'
      end

      it 'suppresses reasoning in the response body and caps reasoning effort' do
        stub_groq
        service.send(:call_groq, 'test prompt')
        expect(last_request_body['include_reasoning']).to be(false)
        expect(last_request_body['reasoning_effort']).to eq('low')
      end

      it 'returns the answer content, not the reasoning' do
        stub_groq(content: '2')
        expect(service.send(:call_groq, 'test prompt')).to eq('2')
      end

      it 'returns nil on API error rather than raising' do
        stub_groq(status: 500)
        expect(service.send(:call_groq, 'test prompt')).to be_nil
      end
    end
  end

  describe 'AiProductGrouper duplicate validation' do
    it 'no longer caps the YES/NO call at a budget reasoning would consume' do
      stub_groq(content: 'YES')
      p1 = Struct.new(:name).new('TOMATO ROMA 25LB')
      p2 = Struct.new(:name).new('ROMA TOMATOES CASE 25 LB')

      expect(AiProductGrouper.new.send(:validate_duplicate_with_ai, p1, p2)).to be(true)
      expect(last_request_body['max_tokens']).to be >= MIN_SAFE_BUDGET
    end
  end

  describe PdfParsingService do
    let(:service) do
      svc = described_class.allocate
      svc.instance_variable_set(:@api_key, 'test-key')
      svc
    end

    it 'requests the replacement model with reasoning suppressed' do
      stub_groq(content: '{"products":[]}')
      service.send(:call_groq_api, 'some price list text')

      body = last_request_body
      expect(body['model']).to eq('openai/gpt-oss-120b')
      expect(body['include_reasoning']).to be(false)
      expect(body['reasoning_effort']).to eq('low')
    end

    it 'keeps a large budget so long price lists do not truncate mid-JSON' do
      stub_groq(content: '{"products":[]}')
      service.send(:call_groq_api, 'some price list text')
      expect(last_request_body['max_tokens']).to be >= 16_384
    end
  end

  describe MenuPlannerService do
    let(:event_plan) { double('EventPlan', organization: nil) }
    let(:service) do
      svc = described_class.new(event_plan: event_plan, user_message: 'plan a dinner')
      svc.instance_variable_set(:@api_key, 'test-key')
      allow(svc).to receive(:build_conversation_messages)
        .and_return([{ role: 'user', content: 'plan a dinner' }])
      svc
    end

    it 'requests the replacement model in JSON mode' do
      stub_groq(content: '{"summary":"ok"}')
      service.send(:call_groq)

      body = last_request_body
      expect(body['model']).to eq('openai/gpt-oss-120b')
      expect(body.dig('response_format', 'type')).to eq('json_object')
    end

    # Live-verified: reasoning_effort "high" with response_format json_object
    # makes Groq return HTTP 400 json_validate_failed. "low" is required here,
    # not merely a token optimisation.
    it 'pins reasoning effort to low, which JSON mode requires' do
      stub_groq(content: '{"summary":"ok"}')
      service.send(:call_groq)
      expect(last_request_body['reasoning_effort']).to eq('low')
    end

    it 'suppresses reasoning so it cannot land in the JSON body the parser reads' do
      stub_groq(content: '{"summary":"ok"}')
      service.send(:call_groq)
      expect(last_request_body['include_reasoning']).to be(false)
    end

    it 'keeps a budget large enough for a full multi-course menu' do
      stub_groq(content: '{"summary":"ok"}')
      service.send(:call_groq)
      expect(last_request_body['max_tokens']).to be >= 8192
    end

    describe 'rate limiting' do
      before { allow(service).to receive(:sleep) }

      it 'retries once on 429 and returns the content on success' do
        stub_request(:post, GROQ_ENDPOINT)
          .to_return(status: 429, headers: { 'retry-after' => '2' }, body: '{}')
          .then
          .to_return(
            status: 200,
            headers: { 'Content-Type' => 'application/json' },
            body: { choices: [{ message: { content: '{"summary":"ok"}' } }] }.to_json
          )

        expect(service.send(:call_groq)).to eq('{"summary":"ok"}')
        expect(a_request(:post, GROQ_ENDPOINT)).to have_been_made.twice
      end

      it 'gives up after the retry budget and returns nil' do
        stub_request(:post, GROQ_ENDPOINT)
          .to_return(status: 429, headers: { 'retry-after' => '2' }, body: '{}')

        expect(service.send(:call_groq)).to be_nil
        expect(a_request(:post, GROQ_ENDPOINT))
          .to have_been_made.times(MenuPlannerService::RATE_LIMIT_RETRIES + 1)
      end
    end

    describe '#rate_limit_wait' do
      def response_with(headers)
        double('response', headers: headers)
      end

      it 'honours retry-after' do
        expect(service.send(:rate_limit_wait, response_with('retry-after' => '7'))).to eq(7)
      end

      it 'falls back to the token reset hint, parsing Groq duration strings' do
        wait = service.send(:rate_limit_wait, response_with('x-ratelimit-reset-tokens' => '22.447s'))
        expect(wait).to eq(23)
      end

      it 'falls back to a default when no hint is present' do
        expect(service.send(:rate_limit_wait, response_with({})))
          .to eq(MenuPlannerService::RATE_LIMIT_DEFAULT_WAIT)
      end

      it 'clamps an absurd header so the job cannot stall for minutes' do
        expect(service.send(:rate_limit_wait, response_with('retry-after' => '9999')))
          .to eq(MenuPlannerService::RATE_LIMIT_MAX_WAIT)
      end
    end
  end
end
