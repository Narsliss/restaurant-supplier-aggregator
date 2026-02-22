class AddCheckoutEnabledToSuppliers < ActiveRecord::Migration[7.1]
  def change
    add_column :suppliers, :checkout_enabled, :boolean, default: false, null: false

    reversible do |dir|
      dir.up do
        # Enable checkout for suppliers with working checkout implementations
        execute <<-SQL
          UPDATE suppliers SET checkout_enabled = true
          WHERE code IN ('usfoods', 'whatchefswant')
        SQL
      end
    end
  end
end
