# ============================================================
# Public IP for Application Gateway
# Standard_v2 SKU はパブリック IP が必須 (Azure 側の制約)
# Private Deployment (パブリック IP なし) は Standard / WAF (v1) SKU のみ対応
# 今回の最小構成では Standard_v2 を使用するため public IP は必須だが、
# 実際のルーティングは AGIC の usePrivateIP: true によりプライベート IP 経由のみで行われる
# ============================================================
resource "azurerm_public_ip" "appgw" {
  name                = "agic-green-appgw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ============================================================
# Application Gateway (Standard_v2)
# ============================================================
resource "azurerm_application_gateway" "appgw" {
  name                = "agic-green-appgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_ip_configuration {
    name                          = "appgw-private-frontend"
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address            = "10.0.1.10"
    private_ip_address_allocation = "Static"
  }

  # Placeholder — AGIC が起動後に上書きする
  backend_address_pool {
    name = "placeholder-backend-pool"
  }

  backend_http_settings {
    name                  = "placeholder-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "placeholder-listener"
    frontend_ip_configuration_name = "appgw-public-frontend"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "placeholder-routing-rule"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = "placeholder-listener"
    backend_address_pool_name  = "placeholder-backend-pool"
    backend_http_settings_name = "placeholder-http-settings"
  }

  # AGIC が管理するフィールドの差分を無視
  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      http_listener,
      probe,
      request_routing_rule,
      url_path_map,
      tags,
    ]
  }
}
