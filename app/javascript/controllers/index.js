import { application } from "./application"

import TwoFactorController from "./two_factor_controller"
import FlashController from "./flash_controller"
import DropdownController from "./dropdown_controller"
import MobileMenuController from "./mobile_menu_controller"
import PasswordToggleController from "./password_toggle_controller"
import CredentialValidatorController from "./credential_validator_controller"
import ProductSearchController from "./product_search_controller"
import CategoryFilterController from "./category_filter_controller"
import CredentialFormController from "./credential_form_controller"
import InlineFormController from "./inline_form_controller"
import SearchableSelectController from "./searchable_select_controller"
import OrderBuilderController from "./order_builder_controller"
import OrderReviewController from "./order_review_controller"
import ThemeController from "./theme_controller"

application.register("two-factor", TwoFactorController)
application.register("flash", FlashController)
application.register("dropdown", DropdownController)
application.register("mobile-menu", MobileMenuController)
application.register("password-toggle", PasswordToggleController)
application.register("credential-validator", CredentialValidatorController)
application.register("product-search", ProductSearchController)
application.register("category-filter", CategoryFilterController)
application.register("credential-form", CredentialFormController)
application.register("inline-form", InlineFormController)
application.register("searchable-select", SearchableSelectController)
application.register("order-builder", OrderBuilderController)
application.register("order-review", OrderReviewController)
application.register("theme", ThemeController)
