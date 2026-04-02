# ============================================================
# Private AppGW — WAF_v2 (オンプレ / Hub VNet からのアクセス用)
# WAF_v2 SKU ではパブリック IP が必須 (Azure 制約)
# 実際のルーティングは AGIC の usePrivateIP: true によりプライベート IP 経由のみ
# ============================================================

# --- WAF Policy ---
resource "azurerm_web_application_firewall_policy" "private" {
  name                = "multi-appgw-waf-policy-private"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  policy_settings {
    enabled                     = true
    mode                        = "Detection" # 検証環境のため Detection — 本番では Prevention に変更
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

# --- Public IP (WAF_v2 必須 — 実際のルーティングには使用しない) ---
resource "azurerm_public_ip" "appgw_private" {
  name                = "multi-appgw-private-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- Application Gateway ---
# WAF Policy は AppGW リソースの firewall_policy_id で直接紐付け
# (単一 AppGW 構成では Ingress アノテーション waf-policy-for-path で紐付け)
resource "azurerm_application_gateway" "private" {
  name                = "multi-appgw-private"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  firewall_policy_id  = azurerm_web_application_firewall_policy.private.id

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = 1 # コスト最小 (0 にしても固定費は発生する)
    max_capacity = 2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_private.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  # パブリック Frontend (WAF_v2 必須)
  frontend_ip_configuration {
    name                 = "appgw-public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw_private.id
  }

  # プライベート Frontend (実際のアクセスはこちら)
  frontend_ip_configuration {
    name                          = "appgw-private-frontend"
    subnet_id                     = azurerm_subnet.appgw_private.id
    private_ip_address            = "10.2.1.10"
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
