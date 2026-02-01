import { application } from "./application"

import TwoFactorController from "./two_factor_controller"
import FlashController from "./flash_controller"
import DropdownController from "./dropdown_controller"
import MobileMenuController from "./mobile_menu_controller"
import PasswordToggleController from "./password_toggle_controller"

application.register("two-factor", TwoFactorController)
application.register("flash", FlashController)
application.register("dropdown", DropdownController)
application.register("mobile-menu", MobileMenuController)
application.register("password-toggle", PasswordToggleController)
