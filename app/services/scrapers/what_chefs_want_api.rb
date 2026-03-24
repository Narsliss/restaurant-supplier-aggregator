# frozen_string_literal: true

module Scrapers
  class WhatChefsWantApi
    GRAPHQL_URL = 'https://whatchefswant.cutanddry.com/GraphQLController'
    BASE_URL = 'https://whatchefswant.cutanddry.com'

    attr_reader :credential, :vendor_id, :location_id, :form_id, :verified_vendor_id

    def initialize(credential)
      @credential = credential
      @cookies = {}
      @csrf_token = nil
      @http = nil
      @logger = Rails.logger
      @vendor_id = nil
      @location_id = nil
      @form_id = nil
      @verified_vendor_id = nil
    end

    # ----------------------------------------------------------------
    # Session Management
    # ----------------------------------------------------------------

    def restore_session
      raw = credential.session_data
      session = if raw.is_a?(String)
                  JSON.parse(raw) rescue {}
                else
                  raw || {}
                end

      # Restore cookies
      api_cookies = session['api_cookies']
      return false unless api_cookies.is_a?(Hash) && api_cookies.any?

      @cookies = api_cookies.dup
      @csrf_token = api_cookies['x-csrf-v1'] || session.dig('api_context', 'csrf_token')

      # Restore context IDs
      ctx = session['api_context']
      if ctx
        @vendor_id = ctx['vendor_id']
        @location_id = ctx['location_id']
        @form_id = ctx['form_id']
        @verified_vendor_id = ctx['verified_vendor_id']
      end

      # Validate session with a lightweight query
      result = fetch_user
      if result
        @logger.info '[WCW-API] Session restored successfully'
        # Re-discover context if missing
        discover_context unless @vendor_id && @location_id && @form_id
        true
      else
        @logger.info '[WCW-API] Session cookies expired'
        false
      end
    rescue StandardError => e
      @logger.warn "[WCW-API] Session restore failed: #{e.message}"
      false
    end

    def ensure_session!
      return if @vendor_id && @location_id && @form_id && @cookies.any?

      # Reload credential from DB — another job may have refreshed
      # the session while we were queued.
      credential.reload
      unless restore_session
        raise Scrapers::BaseScraper::AuthenticationError, 'WCW API session not available — login required'
      end
    end

    # Call this after an auth error to attempt recovery.
    def handle_auth_failure
      @logger.info '[WCW-API] Auth failure — reloading session from DB...'
      credential.reload
      @cookies = {}
      @vendor_id = nil
      restore_session
    end

    def set_cookies_from_browser(cookies_hash, csrf_token = nil)
      @cookies = cookies_hash.transform_keys(&:to_s)
      @csrf_token = csrf_token || @cookies['x-csrf-v1']
      save_session_cookies
    end

    def save_session_cookies
      session = if credential.session_data.is_a?(String)
                  JSON.parse(credential.session_data) rescue {}
                else
                  credential.session_data || {}
                end
      session['api_cookies'] = @cookies
      session['api_context'] = {
        'vendor_id' => @vendor_id,
        'location_id' => @location_id,
        'form_id' => @form_id,
        'verified_vendor_id' => @verified_vendor_id,
        'csrf_token' => @csrf_token
      }
      credential.update!(session_data: session.to_json)
    end

    # ----------------------------------------------------------------
    # Context Discovery — extract IDs dynamically
    # ----------------------------------------------------------------

    def discover_context
      @logger.info '[WCW-API] Discovering vendor/location/form context...'

      # Get vendors and locations from the company
      vendors_data = fetch_vendors
      return false unless vendors_data

      company = vendors_data.dig('data', 'company')
      return false unless company

      vendors = company['vendors'] || []
      # Find the WCW vendor (non-archived, with forms)
      vendor = vendors.find { |v| !v['archived'] && (v['forms'] || []).any? }
      unless vendor
        @logger.error '[WCW-API] No active vendor found'
        return false
      end

      @vendor_id = vendor['id']
      @logger.info "[WCW-API] Vendor: #{vendor['name']} (#{@vendor_id})"

      # Get verified vendor ID
      vv = vendor.dig('verifiedvendor', 'id')
      @verified_vendor_id = vv if vv
      @logger.info "[WCW-API] Verified vendor: #{@verified_vendor_id}"

      # Get location (first active)
      locations = vendor['activeLocations'] || vendor['locations'] || []
      location = locations.first
      if location
        @location_id = location['id']
        @logger.info "[WCW-API] Location: #{location['name']} (#{@location_id})"
      end

      # Get form (order guide) — prefer default, fall back to first
      forms = vendor['forms'] || []
      form = forms.find { |f| !f['archived'] && !f['isEmpty'] } || forms.first
      if form
        @form_id = form['id']
        @logger.info "[WCW-API] Form: #{form['name'] || form['id']} (#{@form_id})"
      end

      save_session_cookies
      @vendor_id && @location_id && @form_id
    end

    # ----------------------------------------------------------------
    # User / Auth Queries
    # ----------------------------------------------------------------

    def fetch_user
      graphql_request('user', user_query, {})
    end

    def fetch_vendors
      graphql_request('vendors', vendors_query, {})
    end

    # ----------------------------------------------------------------
    # Catalog Operations
    # ----------------------------------------------------------------

    def search_products(term, limit: 25, offset: 0, delivery_date: nil)
      delivery_date ||= next_delivery_date_str
      graphql_request('ConsumerCanonicalProductsSearchQuery', search_products_query, {
        verifiedVendorId: @verified_vendor_id,
        locationId: @location_id,
        searchString: term,
        activeOnly: true,
        showHidden: false,
        fuzziness: 'AUTO',
        limit: limit,
        offset: offset,
        showSpecialItems: false,
        deliveryDate: delivery_date,
        considerProductAvailability: true,
        ignoreAdvertisedProducts: false,
        showInstacartAds: false,
        source: 'catalog_search_carousel'
      })
    end

    def get_categories
      graphql_request('CatalogCategoryOptionsQuery', categories_query, {
        verifiedVendorId: @verified_vendor_id,
        activeOnly: true,
        showHidden: false,
        applyUomWiseVisibilityFilter: true,
        locationId: @location_id,
        applyPublicCatalogFilter: false,
        showSpecialItems: false,
        hideNewProducts: false
      })
    end

    def browse_category(category_id, limit: 50, offset: 0, delivery_date: nil, subcategory_id: nil)
      delivery_date ||= next_delivery_date_str
      graphql_request('ConsumerCanonicalProductsByCategoriesQuery', browse_category_query, {
        verifiedVendorId: @verified_vendor_id,
        categoryId: category_id,
        subcategoryId: subcategory_id,
        locationId: @location_id,
        deliveryDate: delivery_date,
        limit: limit,
        offset: offset,
        showHidden: false,
        applyUomWiseVisibilityFilter: true,
        sortBy: 'productName',
        sortDirection: 'asc',
        applyPublicCatalogFilter: false,
        showSpecialItems: false,
        hideNewProducts: false,
        ignoreAdvertisedProducts: false,
        showInstacartAds: false
      })
    end

    def get_order_guides
      graphql_request('orderGuidesForVendorLocation', order_guides_query, {
        vendorId: @vendor_id,
        locationId: @location_id,
        filterByCatalogAccess: false
      })
    end

    def get_order_guide_items(form_id: nil, limit: 100, offset: 0, delivery_date: nil)
      form_id ||= @form_id
      delivery_date ||= next_delivery_date_str
      graphql_request('formForOrder', form_for_order_query, {
        formId: form_id,
        locationId: @location_id,
        searchString: '',
        sortView: 'custom_view',
        sortDirection: nil,
        offset: offset,
        limit: limit,
        deliveryDate: delivery_date,
        useElasticSearch: true,
        sectionId: nil,
        sectionCategoryId: nil,
        applyCategorySort: false,
        orderHistoryFilter: 'all'
      })
    end

    # ----------------------------------------------------------------
    # Cart / Draft Operations
    # ----------------------------------------------------------------

    def create_draft(delivery_date, items)
      delivery_date_str = delivery_date.is_a?(String) ? delivery_date : delivery_date&.strftime('%Y-%m-%d')
      delivery_date_str ||= next_delivery_date_str

      products = items.map do |item|
        {
          id: item[:product_id].to_s,
          quantity: item[:quantity].to_i,
          sourceData: { sourcePage: 'OrderGuide', sourceLocation: 'API' },
          addedToCartAt: Time.now.to_f,
          truePrice: item[:price].to_f,
          originalPrice: item[:price].to_f
        }
      end

      graphql_request('CreateOrUpdateDraftMutation', create_or_update_draft_mutation, {
        formId: @form_id,
        locationId: @location_id,
        draftId: nil,
        deliveryDate: delivery_date_str,
        products: products,
        instructions: '',
        fulfilmentType: 'delivery',
        poNumber: '',
        memoCode: '',
        multiCartData: []
      })
    end

    def update_draft(draft_id, delivery_date, items)
      delivery_date_str = delivery_date.is_a?(String) ? delivery_date : delivery_date&.strftime('%Y-%m-%d')
      delivery_date_str ||= next_delivery_date_str

      products = items.map do |item|
        {
          id: item[:product_id].to_s,
          quantity: item[:quantity].to_i,
          sourceData: { sourcePage: 'OrderGuide', sourceLocation: 'API' },
          addedToCartAt: Time.now.to_f,
          truePrice: item[:price].to_f,
          originalPrice: item[:price].to_f
        }
      end

      graphql_request('CreateOrUpdateDraftMutation', create_or_update_draft_mutation, {
        formId: @form_id,
        locationId: @location_id,
        draftId: draft_id.to_s,
        deliveryDate: delivery_date_str,
        products: products,
        instructions: '',
        fulfilmentType: 'delivery',
        poNumber: '',
        memoCode: '',
        multiCartData: []
      })
    end

    def get_draft(draft_id)
      graphql_request('singleDraft', single_draft_query, {
        id: draft_id.to_s,
        locationId: @location_id
      })
    end

    def get_all_drafts
      graphql_request('allCompanyDraftsQuery', all_drafts_query, {})
    end

    def delete_draft_items(draft_id, delivery_date = nil)
      delivery_date_str = delivery_date.is_a?(String) ? delivery_date : delivery_date&.strftime('%Y-%m-%d')
      delivery_date_str ||= next_delivery_date_str

      graphql_request('CreateOrUpdateDraftMutation', create_or_update_draft_mutation, {
        formId: @form_id,
        locationId: @location_id,
        draftId: draft_id.to_s,
        deliveryDate: delivery_date_str,
        products: [],
        instructions: '',
        fulfilmentType: 'delivery',
        poNumber: '',
        memoCode: '',
        multiCartData: []
      })
    end

    # ----------------------------------------------------------------
    # Order Operations
    # ----------------------------------------------------------------

    def get_order_minimum(delivery_date: nil)
      delivery_date_str = delivery_date.is_a?(String) ? delivery_date : delivery_date&.strftime('%Y-%m-%d')
      delivery_date_str ||= next_delivery_date_str

      graphql_request('OrderMinimumDataQuery', order_minimum_query, {
        formId: @form_id,
        locationId: @location_id,
        deliveryDate: delivery_date_str
      })
    end

    def get_orders(start_date: nil, end_date: nil)
      start_date ||= 30.days.ago
      end_date ||= Time.current

      graphql_request('OrdersByCustomerQuery', orders_query, {
        createdStartDate: start_date.strftime('%m/%d/%Y %I:%M:%S %p %z'),
        createdEndDate: end_date.strftime('%m/%d/%Y %I:%M:%S %p %z')
      })
    end

    # ----------------------------------------------------------------
    # HTTP / GraphQL Helper
    # ----------------------------------------------------------------

    private

    def graphql_request(operation_name, query, variables)
      uri = URI(GRAPHQL_URL)
      http = ensure_http(uri)

      body = {
        operationName: operation_name,
        variables: variables,
        query: query
      }.to_json

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36'
      request['Origin'] = BASE_URL
      request['Referer'] = "#{BASE_URL}/"
      request['Cookie'] = cookie_header
      request['x-csrf'] = @csrf_token if @csrf_token
      request.body = body

      response = http.request(request)
      extract_cookies(response)

      unless response.is_a?(Net::HTTPSuccess)
        @logger.error "[WCW-API] HTTP #{response.code} for #{operation_name}"
        @logger.error "[WCW-API] Response: #{response.body.to_s[0..500]}"
        return nil
      end

      data = JSON.parse(response.body)
      if data['errors']&.any?
        errors = data['errors'].map { |e| e['message'] }.join(', ')
        @logger.error "[WCW-API] GraphQL errors for #{operation_name}: #{errors}"
      end

      data
    rescue JSON::ParserError => e
      @logger.error "[WCW-API] JSON parse error for #{operation_name}: #{e.message}"
      nil
    rescue Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => e
      @logger.error "[WCW-API] Connection error for #{operation_name}: #{e.message}"
      @http&.finish rescue nil
      @http = nil
      raise  # Re-raise so callers can handle/retry (matches USF/PPO pattern)
    end

    def ensure_http(uri)
      return @http if @http

      @http = Net::HTTP.new(uri.host, uri.port)
      @http.use_ssl = true
      @http.open_timeout = 30
      @http.read_timeout = 60
      @http.keep_alive_timeout = 30
      @http.start
      @http
    end

    def close
      @http&.finish rescue nil
      @http = nil
    end

    def cookie_header
      @cookies.map { |name, value| "#{name}=#{value}" }.join('; ')
    end

    def extract_cookies(response)
      response.get_fields('Set-Cookie')&.each do |cookie_str|
        parts = cookie_str.split(';').first
        name, value = parts.split('=', 2)
        @cookies[name.strip] = value.strip if name && value

        # Capture CSRF token if set via cookie
        if name.strip == 'x-csrf-v1'
          @csrf_token = value.strip
        end
      end
    end

    def next_delivery_date_str
      # Next business day
      date = Date.current + 1
      date += 1 while date.saturday? || date.sunday?
      date.strftime('%Y-%m-%d')
    end

    # ----------------------------------------------------------------
    # GraphQL Queries — simplified versions requesting only needed fields
    # ----------------------------------------------------------------

    def user_query
      <<~GQL
        query user {
          user {
            id
            name
            firstName
            email
            typeOfUser
            role
            company {
              id
              name
              locations {
                id
                name
                __typename
              }
              __typename
            }
            visibleLocations {
              id
              name
              __typename
            }
            __typename
          }
          isLoggedIn
        }
      GQL
    end

    def vendors_query
      <<~GQL
        query vendors {
          company {
            id
            vendors {
              id
              name
              archived
              orderingStatus
              forms {
                id
                name
                archived
                isEmpty
                locations {
                  id
                  name
                  __typename
                }
                __typename
              }
              activeLocations {
                id
                name
                __typename
              }
              locations {
                id
                name
                __typename
              }
              verifiedvendor {
                id
                name
                logoURL
                __typename
              }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def search_products_query
      <<~GQL
        query ConsumerCanonicalProductsSearchQuery(
          $verifiedVendorId: ID!, $locationId: ID,
          $searchString: String, $activeOnly: Boolean, $showHidden: Boolean,
          $fuzziness: String, $deliveryDate: String, $limit: Int, $offset: Int,
          $showSpecialItems: Boolean, $considerProductAvailability: Boolean,
          $ignoreAdvertisedProducts: Boolean, $showInstacartAds: Boolean, $source: String
        ) {
          catalogProductsSearchRootQuery(
            verifiedVendorId: $verifiedVendorId
            locationId: $locationId
            searchString: $searchString
            activeOnly: $activeOnly
            showHidden: $showHidden
            fuzziness: $fuzziness
            deliveryDate: $deliveryDate
            limit: $limit
            offset: $offset
            showSpecialItems: $showSpecialItems
            considerProductAvailability: $considerProductAvailability
            ignoreAdvertisedProducts: $ignoreAdvertisedProducts
            showInstacartAds: $showInstacartAds
            source: $source
          ) {
            count
            contextualProducts {
              canonicalProduct {
                id
                itemCode
                description
                brandName
                nameWithoutBrand
                packSize
                isOutOfStock(locationId: $locationId, deliveryDate: $deliveryDate)
                unavailable(locationId: $locationId)
                manufacturer { id name __typename }
                l0category { id name __typename }
                l1category { id name displayName __typename }
                unifiedPrice(locationId: $locationId, deliveryDate: $deliveryDate) {
                  itemCode
                  defaultUnitPrice {
                    unit
                    normalizedUnit
                    netTieredPrices {
                      index
                      price { float money __typename }
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def categories_query
      <<~GQL
        query CatalogCategoryOptionsQuery(
          $verifiedVendorId: ID!, $activeOnly: Boolean, $showHidden: Boolean,
          $applyUomWiseVisibilityFilter: Boolean, $locationId: ID,
          $applyPublicCatalogFilter: Boolean, $showSpecialItems: Boolean,
          $hideNewProducts: Boolean
        ) {
          catalogCategoryOptions(
            verifiedVendorId: $verifiedVendorId
            activeOnly: $activeOnly
            showHidden: $showHidden
            applyUomWiseVisibilityFilter: $applyUomWiseVisibilityFilter
            locationId: $locationId
            applyPublicCatalogFilter: $applyPublicCatalogFilter
            showSpecialItems: $showSpecialItems
            hideNewProducts: $hideNewProducts
          ) {
            category { id name __typename }
            subcategories {
              subcategory { id name __typename }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def browse_category_query
      <<~GQL
        query ConsumerCanonicalProductsByCategoriesQuery(
          $verifiedVendorId: ID!, $categoryId: ID, $subcategoryId: ID,
          $locationId: ID, $deliveryDate: String, $limit: Int, $offset: Int,
          $showHidden: Boolean, $applyUomWiseVisibilityFilter: Boolean,
          $sortBy: String, $sortDirection: String, $applyPublicCatalogFilter: Boolean,
          $showSpecialItems: Boolean, $hideNewProducts: Boolean,
          $ignoreAdvertisedProducts: Boolean, $showInstacartAds: Boolean
        ) {
          catalogProductsRootQuery(
            verifiedVendorId: $verifiedVendorId
            categoryId: $categoryId
            subcategoryId: $subcategoryId
            locationId: $locationId
            showHidden: $showHidden
            applyUomWiseVisibilityFilter: $applyUomWiseVisibilityFilter
            limit: $limit
            offset: $offset
            deliveryDate: $deliveryDate
            sortBy: $sortBy
            sortDirection: $sortDirection
            applyPublicCatalogFilter: $applyPublicCatalogFilter
            showSpecialItems: $showSpecialItems
            hideNewProducts: $hideNewProducts
            ignoreAdvertisedProducts: $ignoreAdvertisedProducts
            showInstacartAds: $showInstacartAds
          ) {
            count
            contextualProducts {
              canonicalProduct {
                id
                itemCode
                description
                pack
                brandName
                nameWithoutBrand
                isOutOfStock(locationId: $locationId, deliveryDate: $deliveryDate)
                unavailable(locationId: $locationId)
                packSize
                l0category { id name __typename }
                l1category { id name __typename }
                unifiedPrice(locationId: $locationId, deliveryDate: $deliveryDate) {
                  itemCode
                  defaultUnitPrice {
                    unit
                    normalizedUnit
                    netTieredPrices {
                      index
                      price { float money __typename }
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def order_guides_query
      <<~GQL
        query orderGuidesForVendorLocation($vendorId: ID!, $locationId: ID, $filterByCatalogAccess: Boolean) {
          company {
            id
            forms(
              activeOnly: true
              vendorId: $vendorId
              locationId: $locationId
              filterByCatalogAccess: $filterByCatalogAccess
            ) {
              id
              name
              isFromIntegration
              isEmpty
              isEditable
              isDefault(locationId: $locationId)
              locations { id name __typename }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def form_for_order_query
      <<~GQL
        query formForOrder(
          $formId: ID!, $locationId: ID!, $deliveryDate: String,
          $offset: Int, $limit: Int, $useElasticSearch: Boolean,
          $sectionId: ID, $sectionCategoryId: ID, $sortView: String,
          $sortDirection: String, $searchString: String,
          $applyCategorySort: Boolean, $orderHistoryFilter: String
        ) {
          formProducts(id: $formId) {
            sectionsWithCount(
              location_id: $locationId
              useElasticSearch: $useElasticSearch
              sectionId: $sectionId
              sectionCategoryId: $sectionCategoryId
              sortView: $sortView
              sortDirection: $sortDirection
              offset: $offset
              limit: $limit
              searchString: $searchString
              applyCategorySort: $applyCategorySort
              orderHistoryFilter: $orderHistoryFilter
            ) {
              sections {
                id
                title
                multiUnitProducts {
                  id
                  itemCode
                  name
                  products {
                    id
                    name
                    unit
                    abbreviatedUnit
                    itemCode
                    isOutOfStock
                    isUnavailable
                    canonicalproduct {
                      id
                      itemCode
                      description
                      pack
                      brandName
                      packSize
                      isOutOfStock(locationId: $locationId, deliveryDate: $deliveryDate)
                      unavailable(locationId: $locationId)
                      unifiedPrice(locationId: $locationId, deliveryDate: $deliveryDate) {
                        itemCode
                        defaultUnitPrice {
                          unit
                          normalizedUnit
                          netTieredPrices {
                            index
                            price { float money __typename }
                            __typename
                          }
                          __typename
                        }
                        __typename
                      }
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
              fullCount
              __typename
            }
            offset
            __typename
          }
        }
      GQL
    end

    def create_or_update_draft_mutation
      <<~GQL
        mutation CreateOrUpdateDraftMutation(
          $formId: ID!, $locationId: ID!, $draftId: ID, $deliveryDate: String,
          $products: [ProductInput], $instructions: String,
          $fulfilmentType: String!, $poNumber: String, $memoCode: String,
          $multiCartData: [SingleCartDataInput]
        ) {
          CreateOrUpdateDraftMutation(
            formId: $formId
            locationId: $locationId
            draftId: $draftId
            deliveryDate: $deliveryDate
            products: $products
            instructions: $instructions
            fulfilmentType: $fulfilmentType
            poNumber: $poNumber
            memoCode: $memoCode
            multiCartData: $multiCartData
          ) {
            id
            updated
            date
            itemCount
            PONumber
            instructions
            fulfilmentType
            location { id name __typename }
            form {
              id
              vendor { id name __typename }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def single_draft_query
      <<~GQL
        query singleDraft($id: ID!, $locationId: ID) {
          draft(id: $id) {
            id
            updated
            date
            itemCount
            PONumber
            instructions
            fulfilmentType
            products(locationId: $locationId) {
              id
              quantity
              itemCode
              instructionText
              multiUnitProduct {
                id
                itemCode
                name
                products {
                  id
                  name
                  unit
                  abbreviatedUnit
                  itemCode
                  canonicalproduct {
                    id
                    itemCode
                    description
                    pack
                    packSize
                    brandName
                    unifiedPrice(locationId: $locationId, deliveryDate: $deliveryDate) {
                      defaultUnitPrice {
                        unit
                        netTieredPrices {
                          index
                          price { float money __typename }
                          __typename
                        }
                        __typename
                      }
                      __typename
                    }
                    __typename
                  }
                  __typename
                }
                __typename
              }
              __typename
            }
            location { id name __typename }
            form {
              id
              vendor { id name __typename }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def all_drafts_query
      <<~GQL
        query allCompanyDraftsQuery {
          allCompanyDrafts {
            id
            date
            itemCount
            fulfilmentType
            location { id name __typename }
            form {
              id
              vendor { id name __typename }
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def order_minimum_query
      <<~GQL
        query OrderMinimumDataQuery($formId: ID!, $locationId: ID, $deliveryDate: String) {
          form(id: $formId) {
            id
            minimumOrderAmount(locationId: $locationId, deliveryDate: $deliveryDate) {
              float
              money
              __typename
            }
            hasHardMinimum(locationId: $locationId)
            softOrderMinimumAmount(locationId: $locationId, deliveryDate: $deliveryDate) {
              float
              money
              __typename
            }
            softOrderMinimumFee(locationId: $locationId) {
              float
              money
              __typename
            }
            __typename
          }
        }
      GQL
    end

    def orders_query
      <<~GQL
        query OrdersByCustomerQuery($createdStartDate: String, $createdEndDate: String) {
          ordersByCustomer(
            createdStartDate: $createdStartDate
            createdEndDate: $createdEndDate
          ) {
            id
            created
            delivery
            formattedDeliveryDate
            invoice
            erpOrderId
            totalNumberOfItems
            status
            statusCode
            total { money __typename }
            form {
              id
              vendor { id name __typename }
              __typename
            }
            location { id name __typename }
            __typename
          }
        }
      GQL
    end
  end
end
