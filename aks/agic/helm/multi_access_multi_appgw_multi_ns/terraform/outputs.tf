output "subscription_id" {
  description = "Azure Subscription ID"
  value       = var.subscription_id
}

output "agic_private_identity_client_id" {
  description = "AGIC Private MI Client ID (helm install --set で使用)"
  value       = azurerm_user_assigned_identity.agic_private.client_id
}

output "agic_public_identity_client_id" {
  description = "AGIC Public MI Client ID (helm install --set で使用)"
  value       = azurerm_user_assigned_identity.agic_public.client_id
}

output "aks_get_credentials_cmd" {
  description = "kubectl コンテキスト設定コマンド"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

output "appgw_private_ip" {
  description = "Private AppGW のプライベート IP (VM からの curl テスト用)"
  value       = "10.2.1.10"
}

output "appgw_public_ip" {
  description = "Public AppGW のパブリック IP (ローカル PC からのテスト用)"
  value       = azurerm_public_ip.appgw_public.ip_address
}

output "test_vm_public_ip" {
  description = "Test VM の SSH 接続先"
  value       = azurerm_public_ip.test_vm.ip_address
}

output "test_vm_ssh_cmd" {
  description = "Test VM への SSH コマンド"
  value       = "ssh ${var.vm_admin_username}@${azurerm_public_ip.test_vm.ip_address}"
}

output "firewall_private_ip" {
  description = "Azure Firewall のプライベート IP (UDR next hop)"
  value       = azurerm_firewall.fw.ip_configuration[0].private_ip_address
}
