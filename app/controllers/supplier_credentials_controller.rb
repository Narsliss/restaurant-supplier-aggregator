class SupplierCredentialsController < ApplicationController
  before_action :set_credential, only: [:show, :edit, :update, :destroy, :validate, :refresh_session, :import_products]
  before_action :set_suppliers, only: [:new, :create, :edit, :update]

  def index
    @credentials = current_user.supplier_credentials
      .includes(:supplier)
      .order("suppliers.name")
  end

  def show
  end

  def new
    @credential = current_user.supplier_credentials.new
  end

  def create
    @credential = current_user.supplier_credentials.new(credential_params)

    # Validate supplier exists and is active
    if @credential.supplier_id.present?
      supplier = Supplier.find_by(id: @credential.supplier_id)
      if supplier.nil?
        @credential.errors.add(:supplier_id, "is not a valid supplier")
        render :new, status: :unprocessable_entity and return
      elsif !supplier.active?
        @credential.errors.add(:supplier_id, "\"#{supplier.name}\" is currently inactive and not accepting new connections")
        render :new, status: :unprocessable_entity and return
      end
    end

    # Check for duplicate credentials
    existing = current_user.supplier_credentials.find_by(
      supplier_id: @credential.supplier_id
    )
    if existing
      supplier_name = existing.supplier.name
      @credential.errors.add(:base, "You already have credentials for #{supplier_name}. Please edit the existing credential instead.")
      render :new, status: :unprocessable_entity and return
    end

    if @credential.save
      Rails.logger.info "[SupplierCredentials] Created credential ##{@credential.id} for #{@credential.supplier.name} (user: #{current_user.id})"

      # Run validation synchronously so user gets immediate feedback
      result = validate_credential_now(@credential)

      if result[:valid]
        redirect_to supplier_credentials_path,
          notice: "#{@credential.supplier.name} credentials verified successfully."
      elsif result[:two_fa_required]
        redirect_to supplier_credentials_path,
          notice: "#{@credential.supplier.name} credentials saved. A verification code is required — please enter the code sent to your phone or email."
      else
        redirect_to supplier_credentials_path,
          alert: "#{@credential.supplier.name} credentials saved but validation failed: #{result[:message]}"
      end
    else
      Rails.logger.warn "[SupplierCredentials] Failed to create credential: #{@credential.errors.full_messages.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    # Don't allow changing supplier on an existing credential
    if credential_params[:supplier_id].present? && credential_params[:supplier_id].to_i != @credential.supplier_id
      @credential.errors.add(:supplier_id, "cannot be changed. Please delete this credential and create a new one for a different supplier.")
      render :edit, status: :unprocessable_entity and return
    end

    # Strip blank password so it doesn't overwrite existing
    filtered_params = credential_params.dup
    filtered_params.delete(:password) if filtered_params[:password].blank?

    if @credential.update(filtered_params)
      Rails.logger.info "[SupplierCredentials] Updated credential ##{@credential.id} for #{@credential.supplier.name} (user: #{current_user.id})"

      result = validate_credential_now(@credential)

      if result[:valid]
        redirect_to supplier_credentials_path,
          notice: "#{@credential.supplier.name} credentials updated and verified successfully."
      elsif result[:two_fa_required]
        redirect_to supplier_credentials_path,
          notice: "#{@credential.supplier.name} credentials updated. A verification code is required — please enter the code sent to your phone or email."
      else
        redirect_to supplier_credentials_path,
          alert: "#{@credential.supplier.name} credentials updated but validation failed: #{result[:message]}"
      end
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
    # Check if credential is on hold
    if @credential.on_hold?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
            alert: "#{@credential.supplier.name} account is on hold#{@credential.hold_reason.present? ? ": #{@credential.hold_reason}" : ''}. Please contact the supplier to resolve this before validating."
        end
        format.json { render json: { status: "error", message: "Account on hold" }, status: :unprocessable_entity }
      end
      return
    end

    result = validate_credential_now(@credential)

    respond_to do |format|
      if result[:valid]
        format.html do
          redirect_to supplier_credentials_path,
            notice: "#{@credential.supplier.name} credentials verified successfully."
        end
        format.json { render json: { status: "active", credential_id: @credential.id, supplier: @credential.supplier.name } }
      elsif result[:two_fa_required]
        format.html do
          redirect_to supplier_credentials_path,
            notice: "#{@credential.supplier.name} requires a verification code. Please enter the code sent to your phone or email."
        end
        format.json { render json: { status: "two_fa_required", credential_id: @credential.id, supplier: @credential.supplier.name } }
      else
        format.html do
          redirect_to supplier_credentials_path,
            alert: "#{@credential.supplier.name} validation failed: #{result[:message]}"
        end
        format.json { render json: { status: "failed", message: result[:message], credential_id: @credential.id }, status: :unprocessable_entity }
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
        format.json { render json: { status: "error", message: "Cannot refresh: status is #{status_label}" }, status: :unprocessable_entity }
      end
      return
    end

    RefreshSessionJob.perform_later(@credential.id)
    Rails.logger.info "[SupplierCredentials] Session refresh queued for credential ##{@credential.id} — #{@credential.supplier.name} (user: #{current_user.id})"

    last_login_info = if @credential.last_login_at.present?
                        " Last session was #{time_ago_in_words(@credential.last_login_at)} ago."
                      else
                        " No previous session on record."
                      end

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path,
          notice: "Session refresh started for #{@credential.supplier.name}.#{last_login_info}"
      end
      format.json { render json: { status: "refreshing", credential_id: @credential.id, supplier: @credential.supplier.name } }
    end
  end

  def import_products
    unless @credential.active?
      respond_to do |format|
        format.html do
          redirect_to supplier_credentials_path,
            alert: "Cannot import products from #{@credential.supplier.name} — credentials must be validated and active first."
        end
        format.json { render json: { status: "error", message: "Credentials not active" }, status: :unprocessable_entity }
      end
      return
    end

    ImportSupplierProductsJob.perform_later(@credential.id)
    Rails.logger.info "[SupplierCredentials] Product import queued for credential ##{@credential.id} — #{@credential.supplier.name} (user: #{current_user.id})"

    respond_to do |format|
      format.html do
        redirect_to supplier_credentials_path,
          notice: "Product import started for #{@credential.supplier.name}. Products will appear shortly."
      end
      format.json { render json: { status: "importing", credential_id: @credential.id, supplier: @credential.supplier.name } }
    end
  end

  private

  def set_credential
    @credential = current_user.supplier_credentials.find_by(id: params[:id])

    unless @credential
      Rails.logger.warn "[SupplierCredentials] Credential ##{params[:id]} not found for user #{current_user.id}"
      redirect_to supplier_credentials_path, alert: "Credential not found. It may have been deleted."
    end
  end

  def set_suppliers
    existing_supplier_ids = current_user.supplier_credentials.pluck(:supplier_id)

    @available_suppliers = Supplier.active.where.not(id: existing_supplier_ids).order(:name)
    @all_suppliers = Supplier.active.order(:name)
  end

  def credential_params
    params.require(:supplier_credential).permit(:supplier_id, :username, :password)
  end

  def validate_credential_now(credential)
    manager = Authentication::SessionManager.new(credential)
    result = manager.validate_credentials

    if result[:valid]
      credential.mark_active!
    elsif result[:two_fa_required]
      # 2FA pending — keep credential in pending state, don't mark failed
      credential.update!(two_fa_enabled: true, status: "pending")
    else
      credential.mark_failed!(result[:message] || "Validation failed")
    end

    result
  rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
    # Direct raise from scraper (bypasses SessionManager catch)
    credential.update!(two_fa_enabled: true, status: "pending")
    { valid: false, two_fa_required: true, message: "Verification code required. Check your phone or email." }
  rescue => e
    Rails.logger.error "[SupplierCredentials] Validation error: #{e.message}"
    credential.mark_failed!(e.message)
    { valid: false, message: e.message }
  end
end
