# ============================================================
# Azure Firewall — Basic SKU (コスト最小: ~$0.10/hr)
# AKS Egress を LB ではなく Firewall 経由にする
# ============================================================

resource "azurerm_public_ip" "fw" {
  name                = "single-appgw-fw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "fw_mgmt" {
  name                = "single-appgw-fw-mgmt-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_firewall_policy" "fw" {
  name                = "single-appgw-fw-policy"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
}

resource "azurerm_firewall" "fw" {
  name                = "single-appgw-fw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Basic"
  firewall_policy_id  = azurerm_firewall_policy.fw.id

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.azurefw.id
    public_ip_address_id = azurerm_public_ip.fw.id
  }

  management_ip_configuration {
    name                 = "fw-mgmt-ipconfig"
    subnet_id            = azurerm_subnet.azurefw_mgmt.id
    public_ip_address_id = azurerm_public_ip.fw_mgmt.id
  }
}

# ============================================================
# Firewall Rules — AKS Egress 許可
# 検証環境のため広めに許可。本番では最小限に絞ること。
# ============================================================
resource "azurerm_firewall_policy_rule_collection_group" "aks_egress" {
  name               = "aks-egress-rules"
  firewall_policy_id = azurerm_firewall_policy.fw.id
  priority           = 100

  network_rule_collection {
    name     = "aks-network-rules"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "AllowAzureCloud"
      protocols             = ["TCP"]
      source_addresses      = ["10.2.2.0/24"]
      destination_addresses = ["AzureCloud"]
      destination_ports     = ["443", "9000"]
    }

    rule {
      name                  = "AllowNTP"
      protocols             = ["UDP"]
      source_addresses      = ["10.2.2.0/24"]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }

    rule {
      name                  = "AllowDNS"
      protocols             = ["UDP"]
      source_addresses      = ["10.2.2.0/24"]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "AllowRFC1918"
      protocols             = ["Any"]
      source_addresses      = ["10.2.2.0/24"]
      destination_addresses = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
      destination_ports     = ["*"]
    }
  }

  network_rule_collection {
    name     = "aks-outbound-http"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "AllowHTTPSOutbound"
      protocols             = ["TCP"]
      source_addresses      = ["10.2.2.0/24"]
      destination_addresses = ["*"]
      destination_ports     = ["80", "443"]
    }
  }
}
