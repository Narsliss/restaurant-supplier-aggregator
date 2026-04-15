module Organizations
  class MembershipsController < ApplicationController
    before_action :set_organization
    before_action :require_owner_or_manager!
    before_action :set_membership, only: [:update, :destroy, :update_locations]

    def update
      # Can't change owner role
      if @membership.owner?
        redirect_to organization_path
        return
      end

      # Can't promote to owner
      if params[:role] == "owner"
        redirect_to organization_path
        return
      end

      # Only manager and chef roles allowed
      unless %w[manager chef].include?(params[:role])
        redirect_to organization_path
        return
      end

      if @membership.update(role: params[:role])
        redirect_to organization_path
      else
        redirect_to organization_path
      end
    end

    # Update restaurant assignments for a member
    def update_locations
      if @membership.owner?
        redirect_to organization_path
        return
      end

      location_ids = params[:location_ids] || []
      @membership.membership_locations.destroy_all
      location_ids.each do |lid|
        location = @organization.locations.find_by(id: lid)
        MembershipLocation.create!(membership: @membership, location: location) if location
      end

      redirect_to organization_path
    end

    def destroy
      # Can't remove owner
      if @membership.owner?
        redirect_to organization_path
        return
      end

      # Can't remove yourself
      if @membership.user == current_user
        redirect_to organization_path
        return
      end

      @membership.deactivate!
      redirect_to organization_path
    end

    private

    def set_organization
      @organization = current_user.current_organization
      redirect_to root_path unless @organization
    end

    def set_membership
      @membership = @organization.memberships.find(params[:id])
    end
  end
end
