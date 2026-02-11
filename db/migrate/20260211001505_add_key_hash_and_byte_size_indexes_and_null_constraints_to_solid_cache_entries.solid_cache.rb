# This migration comes from solid_cache (originally 20240110111600)
class AddKeyHashAndByteSizeIndexesAndNullConstraintsToSolidCacheEntries < ActiveRecord::Migration[7.0]
  def change
    change_column_null :solid_cache_entries, :key_hash, false
    change_column_null :solid_cache_entries, :byte_size, false
    add_index :solid_cache_entries, :key_hash, unique: true
    add_index :solid_cache_entries, [:key_hash, :byte_size]
    add_index :solid_cache_entries, :byte_size
  end
end
