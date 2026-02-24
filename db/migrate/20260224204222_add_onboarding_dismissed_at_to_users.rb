class AddOnboardingDismissedAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :onboarding_dismissed_at, :datetime
  end
end
