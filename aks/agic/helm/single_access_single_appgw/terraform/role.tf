# ============================================================
# Azure RBAC Role Assignments
# ref: memo/ai_order.md §7-2
# ============================================================

# 1. AGIC UAI: Reader @ Resource Group
resource "azurerm_role_assignment" "agic_reader_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 2. AGIC UAI: Contributor @ AppGW
resource "azurerm_role_assignment" "agic_contributor_appgw" {
  scope                = azurerm_application_gateway.appgw.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 3. AGIC UAI: Network Contributor @ appgw-subnet (Route Table join/action)
resource "azurerm_role_assignment" "agic_netcontrib_appgw_subnet" {
  scope                = azurerm_subnet.appgw.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 4. AGIC UAI: Network Contributor @ MC_ RG (Route Table read — 見落としやすい)
resource "azurerm_role_assignment" "agic_netcontrib_mc_rg" {
  scope                = azurerm_kubernetes_cluster.aks.node_resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 5. AKS Control Plane MI: Network Contributor @ aks-subnet
resource "azurerm_role_assignment" "aks_cp_netcontrib_aks_subnet" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}
