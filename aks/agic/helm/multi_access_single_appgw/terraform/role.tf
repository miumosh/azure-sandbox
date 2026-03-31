# ============================================================
# RBAC — AGIC (1 インスタンス)
# ============================================================

resource "azurerm_role_assignment" "agic_reader_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_contributor_appgw" {
  scope                = azurerm_application_gateway.appgw.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# WAF Policy への join/action 権限
# 本構成では Ingress の waf-policy-for-path アノテーションで WAF Policy をルーティングルール単位で紐付けるため、この権限が必須
resource "azurerm_role_assignment" "agic_contributor_waf_private" {
  scope                = azurerm_web_application_firewall_policy.private.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_contributor_waf_public" {
  scope                = azurerm_web_application_firewall_policy.public.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_netcontrib_appgw_subnet" {
  scope                = azurerm_subnet.appgw.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

resource "azurerm_role_assignment" "agic_netcontrib_mc_rg" {
  scope                = azurerm_kubernetes_cluster.aks.node_resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# ============================================================
# RBAC — AKS Control Plane
# ============================================================

resource "azurerm_role_assignment" "aks_cp_netcontrib_aks_subnet" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}
