# ============================================================
# AGIC User-Assigned Managed Identity
# ============================================================
resource "azurerm_user_assigned_identity" "agic" {
  name                = "agic-green-agic-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# ============================================================
# Federated Identity Credential (Workload Identity / OIDC)
# subject は Helm release name "agic" に依存
# release name を変更した場合は subject も合わせて変更が必要
# ============================================================
resource "azurerm_federated_identity_credential" "agic" {
  name      = "agic-federated-credential"
  user_assigned_identity_id = azurerm_user_assigned_identity.agic.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject   = "system:serviceaccount:kube-system:agic-sa-ingress-azure"
}
