# ============================================================
# AKS Cluster
# CNI Overlay / OIDC + Workload Identity / Egress via Firewall
# ============================================================
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "single-appgw-aks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  dns_prefix          = "single-appgw-aks"
  sku_tier            = "Standard"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "systempool"
    node_count     = 1
    vm_size        = "Standard_B2ms"
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.100.0.0/16"
    dns_service_ip      = "10.100.0.10"
    outbound_type       = "userDefinedRouting"
  }

  depends_on = [
    azurerm_subnet_route_table_association.aks,
    azurerm_firewall.fw,
  ]
}
