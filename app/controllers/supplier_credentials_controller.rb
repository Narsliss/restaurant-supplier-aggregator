class SupplierCredentialsController < ApplicationController
  before_action :set_credential,
                only: %i[show edit update destroy validate refresh_session import_products import_lists submit_2fa_code
                         status]
  before_action :set_suppliers, only: %i[new create edit update]

  def index
    @credentials = current_user.supplier_credentials
                               .includes(:supplier)
                               .order('suppliers.name')

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

    # Check for duplicate credentials
    existing = current_user.supplier_credentials.find_by(
      supplier_id: @credential.supplier_id
    )
    if existing
      supplier_name = existing.supplier.name
      @credential.errors.add(:base,
                             "You already have credentials for #{supplier_name}. Please edit the existing credential instead.")
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

  def edit; end

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

    if @credential.update(filtered_params)
      Rails.logger.info "[SupplierCredentials] Updated credential ##{@credential.id} for #{@credential.supplier.name} (user: #{current_user.id})"

      # All validations run async — headless Chrome is too slow on shared
      # Railway vCPUs to block an HTTP request.
      Supplier2faRequest.where(supplier_credential: @credential, status: 'pending').update_all(status: 'cancelled')
      @credential.update!(status: 'pending')
      ValidateCredentialsJob.perform_later(@credential.id)

      message = if @credential.supplier.no_password_required?
                  "#{@credential.supplier.name} credentials updated. Check your email or phone for a verification code."
                else
                  "#{@credential.supplier.name} credentials updated. Re-validating now — this usually takes 15-30 seconds."
                end

      redirect_to supplier_credentials_path, notice: message
    else
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
        format.html { redirect_to supplier_credentials_path, alert: 'Please enter a verification code.' }
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
        format.html { redirect_to supplier_credentials_path, alert: msg }
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

    # Handle race condition: if 2FA was just verified but credential hasn't been
    # marked active yet (background job still running), report as active to prevent
    # UI from reverting to "pending" state
    credential_status = @credential.status
    if credential_status == 'pending' && tfa_request&.verified? && tfa_request.verified_at.present? && tfa_request.verified_at > 5.minutes.ago
      # Check if verification happened recently (within last 5 minutes)
      credential_status = 'active'
    end

    render json: {
      credential: {
        id: @credential.id,
        status: credential_status,
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
        redirect_to supplier_lists_path(syncing: Time.current.to_i),
                    notice: "Importing order guides from #{@credential.supplier.name}..."
      end
      format.json do
        render json: { status: 'importing', credential_id: @credential.id, supplier: @credential.supplier.name }
      end
    end
  end

  private

  def set_credential
    @credential = current_user.supplier_credentials.find_by(id: params[:id])

    return if @credential

    Rails.logger.warn "[SupplierCredentials] Credential ##{params[:id]} not found for user #{current_user.id}"
    redirect_to supplier_credentials_path, alert: 'Credential not found. It may have been deleted.'
  end

  def set_suppliers
    existing_supplier_ids = current_user.supplier_credentials.pluck(:supplier_id)

    @available_suppliers = Supplier.active.where.not(id: existing_supplier_ids).order(:name)
    @all_suppliers = Supplier.active.order(:name)
  end

  def credential_params
    params.require(:supplier_credential).permit(:supplier_id, :username, :password)
  end

end
