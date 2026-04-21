if defined?(Bullet) && Rails.env.development?
  Bullet.enable = true
  Bullet.bullet_logger = true
  Bullet.rails_logger = true
  Bullet.console = true
  Bullet.add_footer = false
  Bullet.raise = false
end
