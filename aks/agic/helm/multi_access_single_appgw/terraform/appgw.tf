# ============================================================
# WAF Policy — Private Ingress 用
# 内部トラフィック向け: Detection モード
# ============================================================
resource "azurerm_web_application_firewall_policy" "private" {
  name                = "single-appgw-waf-policy-private"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  policy_settings {
    enabled                     = true
    mode                        = "Detection" # 内部通信のため Detection
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

# ============================================================
# WAF Policy — Public Ingress 用
# 外部トラフィック向け: Prevention モード
# ============================================================
resource "azurerm_web_application_firewall_policy" "public" {
  name                = "single-appgw-waf-policy-public"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  policy_settings {
    enabled                     = true
    # mode                        = "Prevention" # インターネット公開のため Prevention
    mode                        = "Detection" # 検証のため一時的に Detection
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

# ============================================================
# Public IP — WAF_v2 必須
# ============================================================
resource "azurerm_public_ip" "appgw" {
  name                = "single-appgw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ============================================================
# Application Gateway (WAF_v2) — Private / Public 共用
#
# 1 つの AppGW に Public Frontend と Private Frontend の両方を持つ。
# AGIC が Ingress の use-private-ip アノテーションに応じて
# 適切な Frontend にリスナーを作成する。
#
# WAF Policy の紐付け方式:
#   firewall_policy_id にはグローバルデフォルト (Public 用) を設定。
#   各 Ingress には waf-policy-for-path アノテーションで個別の WAF Policy を割り当てる。
#   (2 AppGW 構成では AppGW の firewall_policy_id に直接紐付けるため
#    アノテーションは不要)
# ============================================================
resource "azurerm_application_gateway" "appgw" {
  name                = "single-appgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  firewall_policy_id  = azurerm_web_application_firewall_policy.public.id

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  # Public Frontend (インターネットからのアクセス)
  frontend_ip_configuration {
    name                 = "appgw-public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Private Frontend (Hub VNet / オンプレからのアクセス)
  frontend_ip_configuration {
    name                          = "appgw-private-frontend"
    subnet_id                     = azurerm_subnet.appgw.id
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
