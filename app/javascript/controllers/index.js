import { application } from "./application"

import TwoFactorController from "./two_factor_controller"
import FlashController from "./flash_controller"
import DropdownController from "./dropdown_controller"

application.register("two-factor", TwoFactorController)
application.register("flash", FlashController)
application.register("dropdown", DropdownController)
