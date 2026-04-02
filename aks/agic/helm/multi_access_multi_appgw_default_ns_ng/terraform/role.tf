# ============================================================
# RBAC — AGIC Private
# ============================================================

resource "azurerm_role_assignment" "agic_private_reader_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic_private.principal_id
}

resource "azurerm_role_assignment" "agic_private_contributor_appgw" {
  scope                = azurerm_application_gateway.private.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_private.principal_id
}

# WAF Policy への join/action 権限
# 本構成では WAF Policy を AppGW の firewall_policy_id で直接紐付けており
# Ingress の waf-policy-for-path アノテーションは使用していないため
# この権限は厳密には不要だが、将来的にアノテーション方式に変更する場合に備えて付与
resource "azurerm_role_assignment" "agic_private_contributor_waf" {
  scope                = azurerm_web_application_firewall_policy.private.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_private.principal_id
}

resource "azurerm_role_assignment" "agic_private_netcontrib_appgw_subnet" {
  scope                = azurerm_subnet.appgw_private.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_private.principal_id
}

resource "azurerm_role_assignment" "agic_private_netcontrib_mc_rg" {
  scope                = azurerm_kubernetes_cluster.aks.node_resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_private.principal_id
}

# ============================================================
# RBAC — AGIC Public
# ============================================================

resource "azurerm_role_assignment" "agic_public_reader_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic_public.principal_id
}

resource "azurerm_role_assignment" "agic_public_contributor_appgw" {
  scope                = azurerm_application_gateway.public.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_public.principal_id
}

# WAF Policy への join/action 権限 (上記 Private 側と同様の理由で予防的に付与)
resource "azurerm_role_assignment" "agic_public_contributor_waf" {
  scope                = azurerm_web_application_firewall_policy.public.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_public.principal_id
}

resource "azurerm_role_assignment" "agic_public_netcontrib_appgw_subnet" {
  scope                = azurerm_subnet.appgw_public.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_public.principal_id
}

resource "azurerm_role_assignment" "agic_public_netcontrib_mc_rg" {
  scope                = azurerm_kubernetes_cluster.aks.node_resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic_public.principal_id
}

# ============================================================
# RBAC — AKS Control Plane
# ============================================================

resource "azurerm_role_assignment" "aks_cp_netcontrib_aks_subnet" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}
