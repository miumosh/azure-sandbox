# ============================================================
# Public AppGW — WAF_v2 (インターネットからのアクセス用)
# ============================================================

# --- WAF Policy ---
resource "azurerm_web_application_firewall_policy" "public" {
  name                = "multi-appgw-waf-policy-public"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  policy_settings {
    enabled                     = true
    mode                        = "Detection"
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

# --- Public IP ---
resource "azurerm_public_ip" "appgw_public" {
  name                = "multi-appgw-public-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- Application Gateway ---
# WAF Policy は AppGW リソースの firewall_policy_id で直接紐付け
resource "azurerm_application_gateway" "public" {
  name                = "multi-appgw-public"
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
    subnet_id = azurerm_subnet.appgw_public.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  # パブリック Frontend (顧客アクセス用)
  frontend_ip_configuration {
    name                 = "appgw-public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw_public.id
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
