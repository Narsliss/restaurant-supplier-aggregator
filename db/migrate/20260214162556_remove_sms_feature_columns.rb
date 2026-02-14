class RemoveSmsFeatureColumns < ActiveRecord::Migration[7.1]
  def change
    # Remove columns added for SMS cutoff alerts feature
    remove_column :users, :phone_verified_at, :datetime if column_exists?(:users, :phone_verified_at)
    remove_column :supplier_credentials, :cutoff_alerts_enabled, :boolean if column_exists?(:supplier_credentials,
                                                                                            :cutoff_alerts_enabled)
    remove_column :supplier_credentials, :last_cutoff_alert_sent_at, :datetime if column_exists?(:supplier_credentials,
                                                                                                 :last_cutoff_alert_sent_at)
  end
end
