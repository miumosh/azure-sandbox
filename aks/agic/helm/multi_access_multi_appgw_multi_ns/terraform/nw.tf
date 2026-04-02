# ============================================================
# Hub VNet — Azure Firewall + Test VM (オンプレ想定)
# ============================================================
resource "azurerm_virtual_network" "hub" {
  name                = "multi-appgw-hub-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.1.0.0/16"]
}

# Azure Firewall Basic は AzureFirewallSubnet + AzureFirewallManagementSubnet が必須
resource "azurerm_subnet" "azurefw" {
  name                 = "AzureFirewallSubnet" # 名前は固定 (Azure 要件)
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.1.0.0/26"] # /26 以上が必須
}

resource "azurerm_subnet" "azurefw_mgmt" {
  name                 = "AzureFirewallManagementSubnet" # 名前は固定 (Basic SKU 要件)
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.1.0.64/26"]
}

resource "azurerm_subnet" "vm" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.1.1.0/24"]
}

# ============================================================
# Spoke VNet — AppGW (Private / Public) + AKS
# ============================================================
resource "azurerm_virtual_network" "spoke" {
  name                = "multi-appgw-spoke-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.2.0.0/16"]
}

resource "azurerm_subnet" "appgw_private" {
  name                 = "appgw-private-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.2.1.0/24"]

  delegation {
    name = "appgw-delegation"
    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "appgw_public" {
  name                 = "appgw-public-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.2.2.0/24"]

  delegation {
    name = "appgw-delegation"
    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.2.3.0/24"]
}

# ============================================================
# VNet Peering — Hub ↔ Spoke
# ============================================================
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "hub-to-spoke"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true

  # Spoke VNet 上のサブネット操作が完了してから作成する
  depends_on = [
    azurerm_subnet_network_security_group_association.aks,
    azurerm_subnet_network_security_group_association.appgw_private,
    azurerm_subnet_network_security_group_association.appgw_public,
    azurerm_subnet_route_table_association.aks,
  ]
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "spoke-to-hub"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true

  # Spoke VNet 上のサブネット操作が完了してから作成する
  depends_on = [
    azurerm_subnet_network_security_group_association.aks,
    azurerm_subnet_network_security_group_association.appgw_private,
    azurerm_subnet_network_security_group_association.appgw_public,
    azurerm_subnet_route_table_association.aks,
  ]
}
