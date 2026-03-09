class UpdateCwOrderMinimumTo400 < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      UPDATE supplier_requirements
      SET numeric_value = 400.00,
          error_message = 'Chef''s Warehouse requires a minimum order of $400.00. Your current total is ${{current_total}}.'
      WHERE supplier_id = (SELECT id FROM suppliers WHERE code = 'chefswarehouse')
        AND requirement_type = 'order_minimum'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE supplier_requirements
      SET numeric_value = 200.00,
          error_message = 'Chef''s Warehouse requires a minimum order of $200.00. Your current total is ${{current_total}}.'
      WHERE supplier_id = (SELECT id FROM suppliers WHERE code = 'chefswarehouse')
        AND requirement_type = 'order_minimum'
    SQL
  end
end
