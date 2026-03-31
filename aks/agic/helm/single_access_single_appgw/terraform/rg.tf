resource "azurerm_resource_group" "rg" {
  name     = "agic-green-rg"
  location = var.location
}
