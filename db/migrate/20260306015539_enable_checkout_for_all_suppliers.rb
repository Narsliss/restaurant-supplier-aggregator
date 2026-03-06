class EnableCheckoutForAllSuppliers < ActiveRecord::Migration[7.1]
  def up
    # Only enable real checkout in production — keep dry runs in dev/test.
    if Rails.env.production?
      execute "UPDATE suppliers SET checkout_enabled = true"
    end
  end

  def down
    if Rails.env.production?
      execute "UPDATE suppliers SET checkout_enabled = false"
    end
  end
end
