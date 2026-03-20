class SupplierCredentialsController < ApplicationController
  before_action :set_credential,
                only: %i[show edit update destroy validate refresh_session import_products import_lists submit_2fa_code
                         status update_display_position]
  before_action :set_suppliers, only: %i[new create edit update]
  before_action :require_operator!, only: %i[new create edit update destroy]
  before_action :require_location_context!

  def index
    @credentials = scoped_credentials
                               .joins(:supplier)
                               .includes(:supplier)
                               .order('supplier_credentials.display_position ASC, suppliers.name ASC')
    @read_only = current_role == 'manager'

    # Pre-compute supplier product stats to avoid N+1 queries in the view.
    # Two queries total instead of 2 per credential.
    supplier_ids = @credentials.map(&:supplier_id).uniq
    @catalog_last_synced = SupplierProduct.where(supplier_id: supplier_ids)
                                          .group(:supplier_id)
                                          .maximum(:last_scraped_at)
    @catalog_product_counts = SupplierProduct.where(supplier_id: supplier_ids)
                                             .group(:supplier_id)
                                             .count

    # Pre-load order requirements per supplier for display on cards
    @supplier_requirements = SupplierRequirement.where(supplier_id: supplier_ids, active: true)
                                                 .where(requirement_type: %w[order_minimum case_minimum])
                                                 .select(:supplier_id, :requirement_type, :numeric_value, :location_id)

    # Load email suppliers for the new section
    @email_suppliers = Supplier.email_suppliers
                               .where(organization_id: current_user.current_organization_id)
                               .order(:name)

    if @email_suppliers.any?
      @email_supplier_stats = InboundPriceList.parsed
        .where(contact_email: @email_suppliers.pluck(:contact_email))
        .select("contact_email, MAX(received_at) as last_received, MAX(product_count) as last_product_count, MAX(list_date) as last_list_date")
        .group(:contact_email)
        .index_by(&:contact_email)
    else
      @email_supplier_stats = {}
    end

    # Load any active 2FA requests so we can show inline code entry.
    # Include "pending" (waiting for code) and "submitted" (code entered, verifying).
    @pending_2fa = Supplier2faRequest
                   .where(user: current_user, status: %w[pending submitted])
                   .where('expires_at > ?', Time.current)
                   .order(created_at: :desc)
                   .index_by(&:supplier_credential_id)
  end

  def show; end

  def new
    @credential = current_user.supplier_credentials.new
  end

  def create
    @credential = current_user.supplier_credentials.new(credential_params)
    @credential.organization = current_user.current_organization
    # Owners can pick a location from the form; chefs use their current location
    @credential.location ||= current_location

    # Validate supplier exists and is active
    if @credential.supplier_id.present?
      supplier = Supplier.find_by(id: @credential.supplier_id)
      if supplier.nil?
        @credential.errors.add(:supplier_id, 'is not a valid supplier')
        render :new, status: :unprocessable_entity and return
      elsif !supplier.active?
        @credential.errors.add(:supplier_id,
                               "\"#{supplier.name}\" is currently inactive and not accepting new connections")
        render :new, status: :unprocessable_entity and return
      end
    end

    # Check for duplicate credentials at this location
    existing = current_user.supplier_credentials.find_by(
      supplier_id: @credential.supplier_id,
      location_id: @credential.location_id
    )
    if existing
      supplier_name = existing.supplier.name
      @credential.errors.add(:base,
                             "You already have credentials for #{supplier_name} at this location. Please edit the existing credential instead.")
      render :new, status: :unprocessable_entity and return
    end

    if @credential.save
      Rails.logger.info "[SupplierCredentials] Created credential ##{@credential.id} for #{@credential.supplier.name} (user: #{current_user.id})"

      # All validations run async — headless Chrome is too slow on shared
      # Railway vCPUs to block an HTTP request.
      @credential.update!(status: 'pending')
      ValidateCredentialsJob.perform_later(@credential.id)

      message = if @credential.supplier.no_password_required?
                  "#{@credential.supplier.name} credentials saved. Check your email or phone for a verification code."
                else
                  "#{@credential.supplier.name} credentials saved. Validating now — this usually takes 15-30 seconds."
                end

      redirect_to supplier_credentials_path, notice: message
    else
      Rails.logger.warn "[SupplierCredentials] Failed to create credential: #{@credential.errors.full_messages.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_requirement_values
  end

  def update
    # Don't allow changing supplier on an existing credential
    if credential_params[:supplier_id].present? && credential_params[:supplier_id].to_i != @credential.supplier_id
      @credential.errors.add(:supplier_id,
                             'cannot be changed. Please delete this credential and create a new one for a different supplier.')
      render :edit, status: :unprocessable_entity and return
    end

    # Strip blank password so it doesn't overwrite existing
    filtered_params = credential_params.dup
    filtered_params.delete(:password) if filtered_params[:password].blank?

    # Track whether actual login credentials changed (vs just requirements)
    credentials_changed = filtered_params[:username].present? && filtered_params[:username] != @credential.username ||
                          filtered_params[:password].present?

    if @credential.update(filtered_params)
      save_supplier_requirements

      Rails.logger.info "[SupplierCredentials] Updated credential ##{@credential.id} for #{@credential.supplier.name} (user: #{current_user.id})"

      if credentials_changed
        # Only re-validate when login credentials actually changed
        Supplier2faRequest.where(supplier_credential: @credential, status: 'pending').update_all(status: 'cancelled')
        @credential.update!(status: 'pending')
        ValidateCredentialsJob.perform_later(@credential.id)

        message = if @credential.supplier.no_password_required?
                    "#{@credential.supplier.name} credentials updated. Check your email or phone for a verification code."
                  else
                    "#{@credential.supplier.name} credentials updated. Re-validating now — this usually takes 15-30 seconds."
                  end
      else
        message = "#{@credential.supplier.name} settings updated."
      end

      redirect_to supplier_credentials_path, notice: message
    else
      load_requirement_values
      Rails.logger.warn "[SupplierCredentials] Failed to update credential ##{@credential.id}: #{@credential.errors.full_messages.join(', ')}"
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    supplier_name = @credential.supplier.name
    credential_id = @credential.id

    if @credential.destroy
      Rails.logger.info "[SupplierCredentials] Deleted credential ##{credential_id} for #{supplier_name} (user: #{current_user.id})"
      redirect_to supplier_credentials_path,
                  notice: "#{supplier_name} credentials have been removed. Any pending orders for this supplier will not be affected."
    else
      Rails.logger.error "[SupplierCredentials] Failed to delete credential ##{credential_id}: #{@credential.errors.full_messages.join(', ')}"
      redirect_to supplier_credentials_path,
                  alert: "Could not remove #{supplier_name} credentials: #{@credential.errors.full_messages.join(', ')}"
    end
  end

  def validate
    # Check if credential is already active, recently validated, AND has a valid session.
    # If the session is expired we must allow re-validation even if the credential is "active"
    # — especially for 2FA suppliers that can't auto-reconnect.
    if @credential.active? && @credential.session_valid? && @credential.last_login_at.present? && @credential.last_login_at > 1.hour.ago
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      notice: "#{@credential.supplier.name} credentials are already validated and active."
        end
        format.json do
          render json: { status: 'already_active', message: 'Credentials are already validated and active.',
                         credential_id: @credential.id }
        end
      end
      return
    end

    # Check if credential is on hold
    if @credential.on_hold?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      alert: "#{@credential.supplier.name} account is on hold#{@credential.hold_reason.present? ? ": #{@credential.hold_reason}" : ''}. Please contact the supplier to resolve this before validating."
        end
        format.json { render json: { status: 'error', message: 'Account on hold' }, status: :unprocessable_entity }
      end
      return
    end

    # All validations run async via the worker process.
    # Headless Chrome is slow on shared Railway vCPUs — blocking the web
    # request would tie up a Puma thread for 30-60+ seconds.
    # Cancel any existing pending 2FA requests for this credential
    Supplier2faRequest.where(supplier_credential: @credential, status: 'pending').update_all(status: 'cancelled')
    @credential.update!(status: 'pending')

    ValidateCredentialsJob.perform_later(@credential.id)

    two_fa_supplier = @credential.supplier.no_password_required?
    message = if two_fa_supplier
                "Validating #{@credential.supplier.name}... Check your email or phone for a verification code."
              else
                "Validating #{@credential.supplier.name} credentials... This usually takes 15-30 seconds."
              end

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path, notice: message
      end
      format.json do
        render json: { status: 'validating', credential_id: @credential.id, supplier: @credential.supplier.name }
      end
    end
  end

  def refresh_session
    # Check if credential is active enough to refresh
    unless @credential.active? || @credential.expired?
      status_label = @credential.status.titleize
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      alert: "Cannot refresh session for #{@credential.supplier.name} — current status is \"#{status_label}\". Please validate the credentials first."
        end
        format.json do
          render json: { status: 'error', message: "Cannot refresh: status is #{status_label}" },
                 status: :unprocessable_entity
        end
      end
      return
    end

    RefreshSessionJob.perform_later(@credential.id)
    Rails.logger.info "[SupplierCredentials] Session refresh queued for credential ##{@credential.id} — #{@credential.supplier.name} (user: #{current_user.id})"

    last_login_info = if @credential.last_login_at.present?
                        " Last session was #{time_ago_in_words(@credential.last_login_at)} ago."
                      else
                        ' No previous session on record.'
                      end

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path,
                    notice: "Session refresh started for #{@credential.supplier.name}.#{last_login_info}"
      end
      format.json do
        render json: { status: 'refreshing', credential_id: @credential.id, supplier: @credential.supplier.name }
      end
    end
  end

  def submit_2fa_code
    code = (params[:code] || '').to_s.strip

    if code.blank?
      respond_to do |format|
        format.html { redirect_to supplier_credentials_path }
        format.json do
          render json: { status: 'error', message: 'Please enter a verification code.' }, status: :unprocessable_entity
        end
      end
      return
    end

    # Find the active 2FA request for this credential (pending = scraper is polling)
    request = Supplier2faRequest.where(
      user: current_user,
      supplier_credential: @credential,
      status: 'pending'
    ).where('expires_at > ?', Time.current).order(created_at: :desc).first

    Rails.logger.info "[2FA] Submit code for credential #{@credential.id} (#{@credential.supplier.name}) - User: #{current_user.email}"
    Rails.logger.info "[2FA] Code provided: #{code.present? ? 'Yes' : 'No'}, length: #{code.length}"
    Rails.logger.info "[2FA] Pending requests found: #{Supplier2faRequest.where(user: current_user,
                                                                                supplier_credential: @credential, status: 'pending').count}"

    unless request
      msg = "No pending verification request found for #{@credential.supplier.name}. Please click Validate to start again."
      Rails.logger.warn "[2FA] No pending request found for credential #{@credential.id}"
      respond_to do |format|
        format.html { redirect_to supplier_credentials_path }
        format.json { render json: { status: 'error', message: msg }, status: :not_found }
      end
      return
    end

    Rails.logger.info "[2FA] Found request ##{request.id}, status: #{request.status}, expires: #{request.expires_at}"

    # Write the code to the DB — the background scraper is polling for this.
    request.record_attempt!(code)
    Rails.logger.info "[2FA] Code recorded for request ##{request.id}"

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path,
                    notice: "Code submitted for #{@credential.supplier.name}. Verifying now..."
      end
      format.json { render json: { status: 'submitted', message: 'Code submitted. Verifying now...' } }
    end
  end

  # JSON endpoint for the Stimulus controller to poll credential + 2FA state.
  def status
    tfa_request = Supplier2faRequest
                  .where(user: current_user, supplier_credential: @credential)
                  .where(status: %w[pending submitted verified failed])
                  .where("expires_at > ? OR (status IN ('verified', 'failed') AND created_at > ?)", Time.current, 5.minutes.ago)
                  .order(created_at: :desc)
                  .first

    # No need to fake credential status as "active" when 2FA is verified —
    # the Stimulus controller now falls through to credential status checks
    # on tfa.verified, showing "Validating..." → "Importing..." → success
    # as the background job completes login and starts imports.

    render json: {
      credential: {
        id: @credential.id,
        status: @credential.status,
        last_error: @credential.last_error,
        supplier_name: @credential.supplier.name,
        importing: @credential.importing?,
        import_progress: @credential.import_progress,
        import_total: @credential.import_total,
        import_status_text: @credential.import_status_text
      },
      two_fa_request: if tfa_request
                        {
                          id: tfa_request.id,
                          status: tfa_request.status,
                          prompt_message: tfa_request.prompt_message,
                          expires_at: tfa_request.expires_at&.iso8601,
                          attempts: tfa_request.attempts
                        }
                      end
    }
  end

  def update_display_position
    position = params[:display_position].to_i
    @credential.update!(display_position: position)

    respond_to do |format|
      format.html { redirect_to supplier_credentials_path }
      format.json { render json: { success: true, display_position: position } }
    end
  end

  def import_products
    unless current_user.super_admin?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      alert: 'Only the system administrator can trigger product imports.'
        end
        format.json do
          render json: { status: 'error', message: 'Not authorized' }, status: :forbidden
        end
      end
      return
    end

    unless @credential.active?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      alert: "Cannot import products from #{@credential.supplier.name} — credentials must be validated and active first."
        end
        format.json do
          render json: { status: 'error', message: 'Credentials not active' }, status: :unprocessable_entity
        end
      end
      return
    end

    if @credential.importing?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      alert: "An import is already in progress for #{@credential.supplier.name}. Please wait for it to finish."
        end
        format.json { render json: { status: 'error', message: 'Import already in progress' }, status: :conflict }
      end
      return
    end

    # Set importing flag NOW (before enqueueing) so the status endpoint immediately
    # reflects the import-in-progress state. Without this, there's a race window
    # where polling sees importing=false + status=active and re-enables the button.
    @credential.update_columns(importing: true)
    ImportSupplierProductsJob.perform_later(@credential.supplier_id)
    Rails.logger.info "[SupplierCredentials] Product import queued for credential ##{@credential.id} — #{@credential.supplier.name} (user: #{current_user.id})"

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path,
                    notice: "Product import started for #{@credential.supplier.name}. Products will appear shortly."
      end
      format.json do
        render json: { status: 'importing', credential_id: @credential.id, supplier: @credential.supplier.name }
      end
    end
  end

  def import_lists
    unless @credential.active?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
                      alert: "Cannot import lists from #{@credential.supplier.name} — credentials must be validated and active first."
        end
        format.json do
          render json: { status: 'error', message: 'Credentials not active' }, status: :unprocessable_entity
        end
      end
      return
    end

    ImportSupplierListsJob.perform_later(@credential.id)
    Rails.logger.info "[SupplierCredentials] List import queued for credential ##{@credential.id} — #{@credential.supplier.name} (user: #{current_user.id})"

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path,
                    notice: "Importing order guides from #{@credential.supplier.name}. Products will appear shortly."
      end
      format.json do
        render json: { status: 'importing', credential_id: @credential.id, supplier: @credential.supplier.name }
      end
    end
  end

  private

  def set_credential
    @credential = scoped_credentials.find_by(id: params[:id])

    return if @credential

    Rails.logger.warn "[SupplierCredentials] Credential ##{params[:id]} not found for user #{current_user.id}"
    redirect_to supplier_credentials_path
  end

  def set_suppliers
    # Only exclude suppliers already connected at the current location
    # (same user can connect the same supplier at different locations)
    existing_supplier_ids = if current_location
      current_user.supplier_credentials.where(location: current_location).pluck(:supplier_id)
    else
      current_user.supplier_credentials.pluck(:supplier_id)
    end

    @available_suppliers = Supplier.active.web_suppliers.where.not(id: existing_supplier_ids).order(:name)
    @all_suppliers = Supplier.active.web_suppliers.order(:name)
    @locations = current_user.current_organization&.locations || []
  end

  def credential_params
    params.require(:supplier_credential).permit(:supplier_id, :username, :password, :location_id)
  end

  def load_requirement_values
    supplier = @credential.supplier
    location = @credential.location
    @order_minimum = SupplierRequirement.effective_for(supplier: supplier, type: 'order_minimum', location: location)&.numeric_value
    @case_minimum = SupplierRequirement.effective_for(supplier: supplier, type: 'case_minimum', location: location)&.numeric_value&.to_i
    # Clear zero values so the form shows blank instead of "0"
    @order_minimum = nil if @order_minimum.to_f.zero?
    @case_minimum = nil if @case_minimum.to_i.zero?
  end

  def save_supplier_requirements
    supplier = @credential.supplier
    location = @credential.location

    save_requirement(supplier, location, 'order_minimum', params[:order_minimum],
      is_blocking: true,
      error_message: 'Order minimum is ${{minimum}}. Current total: ${{current_total}} (need ${{difference}} more).')

    save_requirement(supplier, location, 'case_minimum', params[:case_minimum],
      is_blocking: true,
      error_message: 'Minimum {{minimum}} cases required. You have {{current_count}} items in your order.')
  end

  def save_requirement(supplier, location, type, value, is_blocking:, error_message:)
    numeric = value.to_f

    if numeric > 0
      req = SupplierRequirement.find_or_initialize_by(
        supplier: supplier,
        requirement_type: type,
        location: location
      )
      req.assign_attributes(
        numeric_value: numeric,
        is_blocking: is_blocking,
        active: true,
        error_message: error_message
      )
      req.save!
    else
      SupplierRequirement.where(
        supplier: supplier,
        requirement_type: type,
        location: location
      ).destroy_all
    end
  end

end
