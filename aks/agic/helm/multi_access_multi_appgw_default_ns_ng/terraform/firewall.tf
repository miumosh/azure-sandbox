# ============================================================
# Azure Firewall — Basic SKU (コスト最小: ~$0.10/hr)
# AKS Egress を LB ではなく Firewall 経由にする
# ============================================================

# --- Public IP (データプレーン) ---
resource "azurerm_public_ip" "fw" {
  name                = "multi-appgw-fw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- Public IP (管理プレーン — Basic SKU 必須) ---
resource "azurerm_public_ip" "fw_mgmt" {
  name                = "multi-appgw-fw-mgmt-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- Firewall Policy (Basic tier) ---
resource "azurerm_firewall_policy" "fw" {
  name                = "multi-appgw-fw-policy"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
}

# --- Firewall ---
resource "azurerm_firewall" "fw" {
  name                = "multi-appgw-fw"
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
# Firewall Rules — AKS Egress に必要な通信を許可
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

    # AKS → Azure サービス (API Server, MCR, ARM, AAD, etc.)
    rule {
      name                  = "AllowAzureCloud"
      protocols             = ["TCP"]
      source_addresses      = ["10.2.3.0/24"]
      destination_addresses = ["AzureCloud"]
      destination_ports     = ["443", "9000"]
    }

    # NTP
    rule {
      name                  = "AllowNTP"
      protocols             = ["UDP"]
      source_addresses      = ["10.2.3.0/24"]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }

    # DNS (Azure DNS / kube-dns 経由で外部名前解決)
    rule {
      name                  = "AllowDNS"
      protocols             = ["UDP"]
      source_addresses      = ["10.2.3.0/24"]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    # AKS → Hub/Spoke 内通信 (API server, Firewall 自身等)
    rule {
      name                  = "AllowRFC1918"
      protocols             = ["Any"]
      source_addresses      = ["10.2.3.0/24"]
      destination_addresses = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
      destination_ports     = ["*"]
    }
  }

  # HTTP/HTTPS (コンテナイメージ pull 等)
  # Basic SKU では Application Rule で FQDN フィルタリングが可能
  network_rule_collection {
    name     = "aks-outbound-http"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "AllowHTTPSOutbound"
      protocols             = ["TCP"]
      source_addresses      = ["10.2.3.0/24"]
      destination_addresses = ["*"]
      destination_ports     = ["80", "443"]
    }
  }
}
