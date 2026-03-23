# frozen_string_literal: true

module Scrapers
  # Direct GraphQL API client for Premiere Produce One (Pepper platform).
  # Replaces browser-based scraping for all operations.
  #
  # PPO runs on the Pepper platform (pepr.app) with:
  #   - GraphQL API at api.usepepper.com/v1/graphql
  #   - AWS Cognito authentication with refresh tokens (30-day TTL)
  #   - Full ordering flow: CreateOrder → UpdateCart → ValidateOrder
  #
  # After initial passwordless login (2FA), the Cognito refresh token
  # maintains the session indefinitely via API — no browser needed.
  class PremiereProduceOneApi
    GRAPHQL_URL = 'https://api.usepepper.com/v1/graphql'
    COGNITO_ENDPOINT = 'https://cognito-idp.us-east-1.amazonaws.com'
    COGNITO_CLIENT_ID = 'lk2aec240lkl74akre9mopgto'
    BUSINESS_ORG_UUID = '45f43212-e6c7-4d39-8bcf-1c95c95f520d'
    SUPPLIER_UUID = '181ecb30-4fea-4c2c-bbc9-3afb35c146a3'

    attr_reader :credential, :logger, :restaurant_uuid, :chat_uuid

    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
      @id_token = nil
      @refresh_token = nil
      @restaurant_uuid = nil
      @chat_uuid = nil
    end

    # ── Authentication ────────────────────────────────────────────

    def restore_session
      raw = credential.session_data
      return false if raw.blank?

      session_data = raw.is_a?(String) ? (JSON.parse(raw) rescue {}) : (raw || {})

      # Try saved api_tokens first
      api_tokens = session_data['api_tokens']
      if api_tokens.is_a?(Hash) && api_tokens['id_token'].present?
        @id_token = api_tokens['id_token']
        @refresh_token = api_tokens['refresh_token']
        @restaurant_uuid = api_tokens['restaurant_uuid']
        @chat_uuid = api_tokens['chat_uuid']

        if verify_token
          logger.info '[PPO-API] Session restored from api_tokens'
          return true
        end

        # Token expired — refresh via Cognito
        if @refresh_token.present?
          return true if refresh_cognito_token
        end
      end

      # Fall back to browser localStorage (Cognito tokens)
      ls = session_data['local_storage'] || {}
      id_token_key = ls.keys.find { |k| k.include?('.idToken') }
      refresh_token_key = ls.keys.find { |k| k.include?('.refreshToken') }

      if id_token_key && refresh_token_key
        @id_token = ls[id_token_key]
        @refresh_token = ls[refresh_token_key]

        if verify_token
          save_session_tokens
          logger.info '[PPO-API] Session restored from browser localStorage'
          return true
        end

        # Token expired — refresh via Cognito
        if @refresh_token.present?
          return true if refresh_cognito_token
        end
      end

      logger.info '[PPO-API] No valid session found'
      false
    rescue StandardError => e
      logger.warn "[PPO-API] Session restore failed: #{e.message}"
      false
    end

    def refresh_cognito_token
      return false unless @refresh_token

      require 'net/http'
      logger.info '[PPO-API] Refreshing via Cognito...'

      uri = URI.parse(COGNITO_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      req = Net::HTTP::Post.new('/')
      req['Content-Type'] = 'application/x-amz-json-1.1'
      req['X-Amz-Target'] = 'AWSCognitoIdentityProviderService.InitiateAuth'
      req.body = {
        AuthFlow: 'REFRESH_TOKEN_AUTH',
        ClientId: COGNITO_CLIENT_ID,
        AuthParameters: { REFRESH_TOKEN: @refresh_token }
      }.to_json

      resp = http.request(req)
      return false unless resp.code == '200'

      data = JSON.parse(resp.body)
      auth_result = data['AuthenticationResult']
      return false unless auth_result&.dig('IdToken')

      @id_token = auth_result['IdToken']

      if verify_token
        save_session_tokens
        logger.info '[PPO-API] Cognito token refreshed successfully'
        true
      else
        false
      end
    rescue StandardError => e
      logger.warn "[PPO-API] Cognito refresh failed: #{e.message}"
      false
    end

    def ensure_session!
      return if @id_token.present?
      return if restore_session

      raise BaseScraper::AuthenticationError, 'PPO API session expired — passwordless login required'
    end

    def session_valid?
      @id_token.present?
    end

    # ── Catalog ───────────────────────────────────────────────────

    # Get all products grouped by category (full catalog).
    def get_catalog(item_limit: 5000)
      graphql('Catalog_VariantPackGroupItems', CATALOG_QUERY, {
        itemLimit: item_limit,
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # Get product pricing info for all products.
    def get_product_info_list(delivery_date: nil)
      delivery_date ||= (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      graphql('VariantPackInfoContext_InfoList', INFO_LIST_QUERY, {
        deliveryDate: delivery_date,
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # Search products by query string.
    def search_products(query, delivery_date: nil)
      delivery_date ||= (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      graphql('SearchItems', SEARCH_QUERY, {
        query: query,
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID,
        fulfillmentDate: delivery_date
      })
    end

    # Get product category groups.
    def get_groups
      graphql('GetGroups', GROUPS_QUERY, {
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # ── Order Guide ───────────────────────────────────────────────

    def get_order_guide_items
      graphql('GetOrderGuideItems', ORDER_GUIDE_QUERY, {
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # Get order guide with pricing info.
    def get_order_guide_info(delivery_date: nil)
      delivery_date ||= (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      graphql('VariantPackInfoContext_OrderGuideInfoList', ORDER_GUIDE_INFO_QUERY, {
        deliveryDate: delivery_date,
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # ── Orders ────────────────────────────────────────────────────

    def create_order(delivery_date: nil)
      delivery_date ||= (Date.today + 1).strftime('%Y-%m-%dT04:00:00.000Z')

      graphql('NewOrder_CreateOrder', CREATE_ORDER_QUERY, {
        deliveryDate: delivery_date,
        fulfillmentType: 'DELIVERY',
        orderDomain: 'GLOBAL',
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # items: [{ variant_pack_id:, quantity:, item_name: }]
    def update_cart(order_uuid, items)
      updated_items = items.map do |item|
        {
          cart_details_at_time_of_order: { quantity: item[:quantity] || 1 },
          variant_pack_id: item[:variant_pack_id],
          item_name: item[:item_name] || ''
        }
      end

      graphql('NewOrder_UpdateCart', UPDATE_CART_QUERY, {
        orderUUID: order_uuid,
        updatedItems: updated_items
      })
    end

    def validate_order(order_uuid)
      graphql('OrderSummary_ValidateOrder', VALIDATE_ORDER_QUERY, {
        locale: 'en',
        orderUUID: order_uuid,
        restaurantUUID: @restaurant_uuid,
        skipSaltApi: false
      })
    end

    def update_fulfillment(order_uuid, delivery_date)
      graphql('NewOrder_UpdateFulfillment', UPDATE_FULFILLMENT_QUERY, {
        orderUUID: order_uuid,
        set: {
          fulfillment_timeslot_end: nil,
          fulfillment_timeslot_start: nil,
          fulfillment_type: 'DELIVERY',
          restaurant_desired_delivery_time: delivery_date
        },
        unplacedOrderStatuses: %w[DRAFT IN_REVIEW]
      })
    end

    def get_open_orders
      graphql('OpenOrders', OPEN_ORDERS_QUERY, {
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    # Submit/place a draft order. THIS PLACES A REAL ORDER.
    def submit_order(order_uuid, po_number: nil, notes: nil)
      graphql('NewOrder_SubmitOrder', SUBMIT_ORDER_QUERY, {
        orderUUID: order_uuid,
        orderNotes: notes,
        paymentMethod: nil,
        poNumber: po_number,
        additionalInputValues: []
      })
    end

    def get_order_history(scope: 'UPCOMING')
      graphql('OrderHistory_SearchOrders', ORDER_HISTORY_QUERY, {
        filters: [{ operation: 'EQUALS', type: 'SCOPE', value: scope }],
        pageSize: 1000,
        restaurantUUID: @restaurant_uuid,
        supplierUUID: SUPPLIER_UUID
      })
    end

    def close
      @graphql_http&.finish rescue nil
      @graphql_http = nil
    end

    private

    # ── GraphQL helper ────────────────────────────────────────────

    def graphql(operation_name, query, variables)
      require 'net/http'

      @graphql_http ||= begin
        uri = URI.parse(GRAPHQL_URL)
        h = Net::HTTP.new(uri.host, uri.port)
        h.use_ssl = true
        h.open_timeout = 15
        h.read_timeout = 60
        h.keep_alive_timeout = 120
        h.start
        h
      end

      uri = URI.parse(GRAPHQL_URL)
      req = Net::HTTP::Post.new(uri.request_uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@id_token}" if @id_token
      req.body = [{
        operationName: operation_name,
        variables: variables,
        query: query
      }].to_json

      resp = @graphql_http.request(req)
      return nil unless resp.code == '200'

      data = JSON.parse(resp.body)
      result = data.is_a?(Array) ? data.first : data

      if result&.dig('errors')
        logger.warn "[PPO-API] GraphQL #{operation_name} errors: #{result['errors'].first['message']}"
        return nil
      end

      result&.dig('data')
    rescue Net::OpenTimeout, Net::ReadTimeout, IOError, Errno::ECONNRESET => e
      logger.warn "[PPO-API] Connection error: #{e.class}, reconnecting..."
      @graphql_http&.finish rescue nil
      @graphql_http = nil
      raise
    rescue StandardError => e
      logger.error "[PPO-API] GraphQL #{operation_name} failed: #{e.class}: #{e.message}"
      nil
    end

    def verify_token
      result = graphql('Auth_Verify', VERIFY_QUERY, {})
      if result&.dig('businesses')
        extract_context(result) unless @restaurant_uuid
        true
      else
        false
      end
    end

    def extract_context(result)
      chats = result['employee_chats'] || []
      if chats.any?
        @restaurant_uuid = chats.first['restaurant_uuid']
        @chat_uuid = chats.first['chat_uuid']
      end
    end

    def save_session_tokens
      raw = credential.session_data
      session_data = if raw.is_a?(String)
                       JSON.parse(raw) rescue {}
                     else
                       raw || {}
                     end

      session_data['api_tokens'] = {
        'id_token' => @id_token,
        'refresh_token' => @refresh_token,
        'restaurant_uuid' => @restaurant_uuid,
        'chat_uuid' => @chat_uuid
      }

      credential.update!(session_data: session_data.to_json)
      logger.info '[PPO-API] Saved API tokens'
    end

    # ── GraphQL Queries ───────────────────────────────────────────

    VERIFY_QUERY = "query Auth_Verify { businesses(where: {uuid: {_eq: \"#{BUSINESS_ORG_UUID}\"}}) { uuid __typename } employee_chats(where: {business_organization_uuid: {_eq: \"#{BUSINESS_ORG_UUID}\"}}) { chat_uuid restaurant_uuid __typename } }"

    CATALOG_QUERY = 'query Catalog_VariantPackGroupItems($itemLimit: Int!, $restaurantUUID: uuid!, $supplierUUID: uuid!) { getSupplierVariantPackGroupItems(restaurant_id: $restaurantUUID, supplier_id: $supplierUUID, variant_pack_group_item_limit: $itemLimit) { variant_pack { external_item_id uuid item { category description display_name uuid __typename } metadata pack { unit unit_count uuid __typename } __typename } variant_pack_group { uuid type __typename } variant_pack_group_display_name variant_pack_group_item_count __typename } }'

    INFO_LIST_QUERY = 'query VariantPackInfoContext_InfoList($deliveryDate: String, $restaurantUUID: uuid!, $supplierUUID: uuid!) { getVariantPackInfoList(delivery_date: $deliveryDate, restaurant_id: $restaurantUUID, supplier_id: $supplierUUID) { availability_status currency_code price_in_micros variant_pack_id unit_count __typename } }'

    ORDER_GUIDE_INFO_QUERY = 'query VariantPackInfoContext_OrderGuideInfoList($deliveryDate: String, $restaurantUUID: uuid!, $supplierUUID: uuid!) { getVariantPackInfoList(delivery_date: $deliveryDate, restaurant_id: $restaurantUUID, supplier_id: $supplierUUID, source: "order_guide") { availability_status currency_code price_in_micros variant_pack_id unit_count __typename } }'

    ORDER_GUIDE_QUERY = 'query GetOrderGuideItems($restaurantUUID: uuid!, $supplierUUID: uuid!) { getOrderGuideItems(restaurant_id: $restaurantUUID, supplier_id: $supplierUUID) { order_guide_item_id variant_pack { external_item_id uuid item { category description display_name uuid __typename } metadata pack { unit unit_count uuid __typename } __typename } __typename } }'

    SEARCH_QUERY = 'query SearchItems($query: String!, $restaurantUUID: uuid!, $supplierUUID: uuid!, $fulfillmentDate: String) { searchVariantPacks(query: $query, restaurant_id: $restaurantUUID, supplier_id: $supplierUUID, fulfillment_date: $fulfillmentDate) { variant_pack { external_item_id uuid item { category description display_name uuid __typename } pack { unit unit_count uuid __typename } __typename } __typename } }'

    GROUPS_QUERY = 'query GetGroups($restaurantUUID: uuid!, $supplierUUID: uuid!) { getVariantPackGroups(restaurant_id: $restaurantUUID, supplier_id: $supplierUUID) { variant_pack_group_id variant_pack_group { uuid type __typename } translated_display_name __typename } }'

    CREATE_ORDER_QUERY = 'mutation NewOrder_CreateOrder($deliveryDate: String!, $fulfillmentType: String!, $orderDomain: OrderDomain!, $restaurantUUID: uuid!, $supplierUUID: uuid!) { createOrder(delivery_date: $deliveryDate, fulfillment_type: $fulfillmentType, order_domain: $orderDomain, restaurant_id: $restaurantUUID, supplier_id: $supplierUUID) { order { uuid status placed_at restaurant_desired_delivery_time fulfillment_type orders_items { restaurant_display_name variants_pack { uuid external_item_id __typename } __typename } __typename } __typename } }'

    UPDATE_CART_QUERY = 'mutation NewOrder_UpdateCart($orderUUID: uuid!, $updatedItems: [UpdateItemInput!]!) { updateCart(order_id: $orderUUID, updated_items: $updatedItems) { order { uuid status orders_items { restaurant_display_name order_item_prices { pack_quantity_at_order __typename } variants_pack { uuid external_item_id __typename } __typename } __typename } __typename } }'

    VALIDATE_ORDER_QUERY = 'mutation OrderSummary_ValidateOrder($locale: String!, $orderUUID: uuid!, $restaurantUUID: uuid!, $skipSaltApi: Boolean!) { validateOrder(order_id: $orderUUID) { alerts { alert_level alert_message } can_place_order missing_essential_item_ids order_minimum { amount is_hard unit } order { uuid status orders_items { uuid restaurant_display_name order_item_prices { currency_code pack_quantity_at_order unit_price_at_order_micros __typename } variants_pack { external_item_id uuid __typename } __typename } __typename } __typename } }'

    UPDATE_FULFILLMENT_QUERY = 'mutation NewOrder_UpdateFulfillment($orderUUID: uuid!, $set: orders_set_input!, $unplacedOrderStatuses: [order_status_enum!]) { update_orders(where: {uuid: {_eq: $orderUUID}, status: {_in: $unplacedOrderStatuses}}, _set: $set) { returning { fulfillment_type restaurant_desired_delivery_time uuid __typename } __typename } }'

    OPEN_ORDERS_QUERY = 'query OpenOrders($restaurantUUID: uuid!, $supplierUUID: uuid!) { orders(where: {supplier_uuid: {_eq: $supplierUUID}, restaurant_uuid: {_eq: $restaurantUUID}, status: {_in: ["DRAFT", "IN_REVIEW"]}}) { uuid status restaurant_desired_delivery_time orders_items { restaurant_display_name variants_pack { uuid external_item_id __typename } __typename } __typename } }'

    SUBMIT_ORDER_QUERY = 'mutation NewOrder_SubmitOrder($orderUUID: uuid!, $orderNotes: String, $paymentMethod: String, $poNumber: String, $additionalInputValues: [AdditionalInputValueInput!]!) { submitOrder(order_id: $orderUUID, order_notes: $orderNotes, payment_method: $paymentMethod, po_number: $poNumber, additional_input_values: $additionalInputValues) { order { uuid status placed_at restaurant_desired_delivery_time __typename } split_order_id_list __typename } }'

    ORDER_HISTORY_QUERY ='query OrderHistory_SearchOrders($filters: [OrderFilterInput!]!, $pageSize: Int!, $restaurantUUID: uuid!, $supplierUUID: uuid!) { searchOrders(filters: $filters, page_size: $pageSize, restaurant_id: $restaurantUUID, supplier_id: $supplierUUID) { orders { uuid status placed_at restaurant_desired_delivery_time orders_items { restaurant_display_name order_item_prices { pack_quantity_at_order unit_price_at_order_micros __typename } __typename } __typename } __typename } }'
  end
end
