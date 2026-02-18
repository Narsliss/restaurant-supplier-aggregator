class ProductsController < ApplicationController
  before_action :require_super_admin, except: [:search]
  before_action :set_product, only: %i[show edit update destroy]

  def index
    per_page = (params[:per_page] || 50).to_i.clamp(10, 200)

    @products = Product.includes(supplier_products: :supplier)
                       .order(:name)
                       .page(params[:page])
                       .per(per_page)

    @products = @products.by_category(params[:category]) if params[:category].present?

    @products = @products.where(subcategory: params[:subcategory]) if params[:subcategory].present?

    if params[:supplier_id].present?
      @products = @products.joins(:supplier_products)
                           .where(supplier_products: { supplier_id: params[:supplier_id] })
                           .distinct
    end

    @products = @products.search(params[:search]) if params[:search].present?

    @suppliers = Supplier.joins(:supplier_products).distinct.order(:name)
    @categories = AiProductCategorizer::CATEGORIES
    @subcategories = params[:category].present? ? @categories.dig(params[:category], :subcategories) || [] : []
  end

  def search
    @products = Product.search(params[:q]).limit(20)

    respond_to do |format|
      format.html { render :index }
      format.json do
        render json: @products.map { |p|
          {
            id: p.id,
            name: p.name,
            category: p.category,
            unit_size: p.unit_size,
            prices: p.supplier_products.available.includes(:supplier).map do |sp|
              {
                supplier: sp.supplier.name,
                price: sp.current_price,
                in_stock: sp.in_stock?
              }
            end
          }
        }
      end
    end
  end

  def show
    @supplier_products = @product.supplier_products
                                 .includes(:supplier)
                                 .order('suppliers.name')
  end

  def new
    @product = Product.new
  end

  def create
    @product = Product.new(product_params)

    if @product.save
      redirect_to @product, notice: 'Product created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @product.update(product_params)
      redirect_to @product, notice: 'Product updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_product
    @product = Product.find(params[:id])
  end

  def product_params
    params.require(:product).permit(:name, :category, :subcategory, :unit_size, :unit_type, :upc, :brand, :description)
  end
end
