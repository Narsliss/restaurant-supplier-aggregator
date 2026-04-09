// Configure your import map in config/importmap.rb
import "@hotwired/turbo-rails"
import "controllers"

// Show Turbo progress bar faster (default 500ms is too slow for mobile)
Turbo.setProgressBarDelay(100)
