# ============================================================
# AKS Cluster
# CNI Overlay / OIDC + Workload Identity / Egress via Firewall
# ============================================================
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "multi-appgw-aks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  dns_prefix          = "multi-appgw-aks"
  sku_tier            = "Standard"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "systempool"
    node_count     = 1
    vm_size        = "Standard_B2ms" # コスト最小 (2 vCPU / 8 GiB)
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
    outbound_type       = "userDefinedRouting" # デフォルト LB を使わず Firewall 経由
  }

  # Route Table + VNet Peering が確立された後に作成する必要がある
  # (UDR 経由で Hub VNet の Firewall に到達するため Peering が必須)
  depends_on = [
    azurerm_subnet_route_table_association.aks,
    azurerm_firewall.fw,
    azurerm_virtual_network_peering.hub_to_spoke,
    azurerm_virtual_network_peering.spoke_to_hub,
  ]
}
