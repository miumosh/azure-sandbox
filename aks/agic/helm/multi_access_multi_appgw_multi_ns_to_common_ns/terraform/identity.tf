# ============================================================
# AGIC Private — User-Assigned Managed Identity
# ============================================================
resource "azurerm_user_assigned_identity" "agic_private" {
  name                = "multi-appgw-agic-private-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# Federated Identity Credential (Workload Identity / OIDC)
# subject は Helm release name "agic-private" に依存
# → SA 名: agic-private-sa-ingress-azure
resource "azurerm_federated_identity_credential" "agic_private" {
  name                          = "agic-private-federated-credential"
  user_assigned_identity_id     = azurerm_user_assigned_identity.agic_private.id
  audience                      = ["api://AzureADTokenExchange"]
  issuer                        = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject                       = "system:serviceaccount:agic-private:agic-private-sa-ingress-azure"
}

# ============================================================
# AGIC Public — User-Assigned Managed Identity
# ============================================================
resource "azurerm_user_assigned_identity" "agic_public" {
  name                = "multi-appgw-agic-public-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# subject は Helm release name "agic-public" に依存
# → SA 名: agic-public-sa-ingress-azure
resource "azurerm_federated_identity_credential" "agic_public" {
  name                          = "agic-public-federated-credential"
  user_assigned_identity_id     = azurerm_user_assigned_identity.agic_public.id
  audience                      = ["api://AzureADTokenExchange"]
  issuer                        = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject                       = "system:serviceaccount:agic-public:agic-public-sa-ingress-azure"
}
