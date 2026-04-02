resource "azurerm_resource_group" "rg" {
  name     = "multi-appgw-rg"
  location = var.location
}
