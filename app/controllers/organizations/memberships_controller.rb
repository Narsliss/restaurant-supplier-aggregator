module Organizations
  class MembershipsController < ApplicationController
    before_action :set_organization
    before_action :require_admin!
    before_action :set_membership, only: [:update, :destroy]

    def update
      # Can't change owner role
      if @membership.owner?
        redirect_to organization_path, alert: "Cannot change the owner's role."
        return
      end

      # Can't promote to owner
      if params[:role] == "owner"
        redirect_to organization_path, alert: "Cannot promote to owner."
        return
      end

      if @membership.update(role: params[:role])
        redirect_to organization_path, notice: "#{@membership.user.full_name}'s role updated to #{@membership.role_display}."
      else
        redirect_to organization_path, alert: "Unable to update role."
      end
    end

    def destroy
      # Can't remove owner
      if @membership.owner?
        redirect_to organization_path, alert: "Cannot remove the organization owner."
        return
      end

      # Can't remove yourself
      if @membership.user == current_user
        redirect_to organization_path, alert: "You cannot remove yourself. Transfer ownership first."
        return
      end

      @membership.deactivate!
      redirect_to organization_path, notice: "#{@membership.user.full_name} has been removed from the organization."
    end

    private

    def set_organization
      @organization = current_user.current_organization
      redirect_to root_path, alert: "No organization selected." unless @organization
    end

    def require_admin!
      unless current_user.admin_of?(@organization)
        redirect_to organization_path, alert: "You don't have permission to manage team members."
      end
    end

    def set_membership
      @membership = @organization.memberships.find(params[:id])
    end
  end
end
