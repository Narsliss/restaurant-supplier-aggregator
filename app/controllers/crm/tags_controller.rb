class Crm::TagsController < Crm::BaseController
  def index
    @tags = Crm::Tag.order(:name)
  end

  def create
    @tag = Crm::Tag.new(tag_params)
    if @tag.save
      redirect_to crm_tags_path, notice: "Tag created."
    else
      redirect_to crm_tags_path, alert: @tag.errors.full_messages.to_sentence
    end
  end

  def destroy
    Crm::Tag.find(params[:id]).destroy
    redirect_to crm_tags_path, notice: "Tag removed."
  end

  private

  def tag_params
    params.require(:crm_tag).permit(:name, :color)
  end
end
