resource "azurerm_resource_group" "rg" {
  name     = "single-appgw-rg"
  location = var.location
}
