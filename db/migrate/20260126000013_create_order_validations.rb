class CreateOrderValidations < ActiveRecord::Migration[7.1]
  def change
    create_table :order_validations do |t|
      t.references :order, null: false, foreign_key: { on_delete: :cascade }
      t.string :validation_type, null: false
      t.boolean :passed, null: false
      t.text :message
      t.jsonb :details, default: {}
      t.datetime :validated_at, null: false

      t.timestamps
    end

    add_index :order_validations, [:order_id, :validation_type]
    add_index :order_validations, :passed
  end
end
