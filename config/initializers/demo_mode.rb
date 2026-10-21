# frozen_string_literal: true

# Sales demo only. Lives on the `demo` branch, never on main
# (docs/plan-demo-site-offline-suppliers.md).
#
# Without DEMO_MODE=true this file stops here: nothing under demo/ is loaded,
# patched or run. Production never sets DEMO_MODE.
return unless ENV['DEMO_MODE'] == 'true'

require Rails.root.join('demo/demo_mode').to_s

DemoMode.install!(Rails.application)
