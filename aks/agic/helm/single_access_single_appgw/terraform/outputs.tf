output "subscription_id" {
  description = "Azure Subscription ID (use in agic-values.yaml)"
  value       = var.subscription_id
}

output "agic_identity_client_id" {
  description = "AGIC User-Assigned MI Client ID (use in agic-values.yaml)"
  value       = azurerm_user_assigned_identity.agic.client_id
}

output "aks_get_credentials_cmd" {
  description = "Command to configure kubectl context"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

output "appgw_private_ip" {
  description = "AppGW private frontend IP (target for curl tests from VM)"
  value       = "10.0.1.10"
}

output "test_vm_public_ip" {
  description = "SSH target for the test VM"
  value       = azurerm_public_ip.test_vm.ip_address
}

output "test_vm_ssh_cmd" {
  description = "SSH command to log into the test VM"
  value       = "ssh ${var.vm_admin_username}@${azurerm_public_ip.test_vm.ip_address}"
}
