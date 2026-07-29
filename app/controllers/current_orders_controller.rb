# Persistence endpoint for the chef's singular working order.
# The builder PUTs the full state on every item add/remove (debounced);
# DELETE is the explicit "Clear order" action.
class CurrentOrdersController < ApplicationController
  # Full builder states stay tiny (match ids + qty/supplier/uom); anything
  # bigger than this is malformed or abusive.
  MAX_STATE_BYTES = 100_000

  # PUT /current_order
  def update
    list = accessible_aggregated_lists.find_by(id: params[:aggregated_list_id])
    return head :not_found unless list

    raw_state = params[:state].respond_to?(:to_unsafe_h) ? params[:state].to_unsafe_h : {}
    return head :payload_too_large if raw_state.to_json.bytesize > MAX_STATE_BYTES

    current_order = CurrentOrder.find_or_initialize_by(user: current_user, aggregated_list: list)
    current_order.state = raw_state
    current_order.delivery_date = params[:delivery_date].presence
    current_order.save!

    head :no_content
  end

  # DELETE /current_order — "Clear order"
  def destroy
    scope = CurrentOrder.where(user: current_user)
    if params[:aggregated_list_id].present?
      scope = scope.where(aggregated_list_id: params[:aggregated_list_id])
    end
    scope.destroy_all

    head :no_content
  end

  private

  def accessible_aggregated_lists
    if current_user.current_organization
      AggregatedList.for_organization(current_user.current_organization)
    else
      current_user.created_aggregated_lists
    end
  end
end
