class FixSyscoSpaceSeparatedPackSizes < ActiveRecord::Migration[7.1]
  # Sysco historically stored case packs as space-separated strings
  # ("12 12 OZ" = 12 bottles x 12 oz). When the count and per-unit size are
  # equal, UnitParser couldn't tell a real case pack from a duplicate-number
  # artifact and treated the whole case as a single unit, inflating the
  # per-unit price (e.g. $91.85 / 12 oz = $7.65/oz instead of / 144 oz).
  #
  # SyscoScraper#build_pack_size now emits an explicit "x" multiplier
  # ("12x12 OZ"). This backfill rewrites existing rows to match so per-unit
  # prices are correct immediately instead of waiting for the next daily import.
  #
  # The regex only rewrites when a digit follows the first space, so catch-weight
  # sizes like "40 LB" (digit + space + unit) are untouched.
  def up
    row = select_one("SELECT id FROM suppliers WHERE LOWER(name) LIKE '%sysco%' LIMIT 1")
    return unless row

    sysco_id = row['id'].to_i

    execute(<<~SQL)
      UPDATE supplier_products
      SET pack_size = regexp_replace(pack_size, '^([0-9]+) ([0-9])', '\\1x\\2')
      WHERE supplier_id = #{sysco_id}
        AND pack_size ~ '^[0-9]+ [0-9]'
    SQL

    execute(<<~SQL)
      UPDATE supplier_list_items
      SET pack_size = regexp_replace(pack_size, '^([0-9]+) ([0-9])', '\\1x\\2')
      WHERE supplier_list_id IN (SELECT id FROM supplier_lists WHERE supplier_id = #{sysco_id})
        AND pack_size ~ '^[0-9]+ [0-9]'
    SQL
  end

  def down
    # Not reversible: the space-vs-"x" distinction is lossy and "x" is the
    # corrected form. No-op.
  end
end
