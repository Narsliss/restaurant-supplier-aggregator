class ProductsController < ApplicationController
  before_action :set_product, only: [:show, :edit, :update]

  def index
    @products = Product.includes(:supplier_products)
      .order(:name)
      .page(params[:page])

    if params[:category].present?
      @products = @products.by_category(params[:category])
    end

    if params[:search].present?
      @products = @products.search(params[:search])
    end
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
            prices: p.supplier_products.includes(:supplier).map { |sp|
              {
                supplier: sp.supplier.name,
                price: sp.current_price,
                in_stock: sp.in_stock?
              }
            }
          }
        }
      end
    end
  end

  def show
    @supplier_products = @product.supplier_products
      .includes(:supplier)
      .order("suppliers.name")
  end

  def new
    @product = Product.new
  end

  def create
    @product = Product.new(product_params)

    if @product.save
      redirect_to @product, notice: "Product created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @product.update(product_params)
      redirect_to @product, notice: "Product updated."
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
