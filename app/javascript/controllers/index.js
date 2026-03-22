import { application } from "./application"

import AdminSearchController from "./admin_search_controller"
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
import OrderStatusController from "./order_status_controller"
import OrderEditController from "./order_edit_controller"
import BatchProgressController from "./batch_progress_controller"
import AutoRefreshController from "./auto_refresh_controller"
import InvitationFormController from "./invitation_form_controller"
import LocationSelectorController from "./location_selector_controller"
import InlineEditController from "./inline_edit_controller"
import ChatController from "./chat_controller"
import DateRangeController from "./date_range_controller"
import ListFilterController from "./list_filter_controller"
import SelectAllController from "./select_all_controller"
import PdfUploadController from "./pdf_upload_controller"
import PriceListStatusController from "./price_list_status_controller"
import DemoLoginController from "./demo_login_controller"
import SpendingTrendController from "./spending_trend_controller"
import DatePresetController from "./date_preset_controller"
import RequirementGridController from "./requirement_grid_controller"

application.register("admin-search", AdminSearchController)
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
application.register("order-status", OrderStatusController)
application.register("order-edit", OrderEditController)
application.register("batch-progress", BatchProgressController)
application.register("auto-refresh", AutoRefreshController)
application.register("invitation-form", InvitationFormController)
application.register("location-selector", LocationSelectorController)
application.register("inline-edit", InlineEditController)
application.register("chat", ChatController)
application.register("date-range", DateRangeController)
application.register("list-filter", ListFilterController)
application.register("select-all", SelectAllController)
application.register("pdf-upload", PdfUploadController)
application.register("price-list-status", PriceListStatusController)
application.register("demo-login", DemoLoginController)
application.register("spending-trend", SpendingTrendController)
application.register("date-preset", DatePresetController)
application.register("requirement-grid", RequirementGridController)
