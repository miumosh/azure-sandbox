output "subscription_id" {
  description = "Azure Subscription ID"
  value       = var.subscription_id
}

output "agic_identity_client_id" {
  description = "AGIC MI Client ID (helm install --set で使用)"
  value       = azurerm_user_assigned_identity.agic.client_id
}

output "aks_get_credentials_cmd" {
  description = "kubectl コンテキスト設定コマンド"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

output "appgw_private_ip" {
  description = "AppGW Private Frontend IP (VM からの Private Ingress テスト用)"
  value       = "10.2.1.10"
}

output "appgw_public_ip" {
  description = "AppGW Public Frontend IP (ローカル PC からの Public Ingress テスト用)"
  value       = azurerm_public_ip.appgw.ip_address
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

# WAF Policy Resource ID (Ingress アノテーションで使用)
output "waf_policy_private_id" {
  description = "Private Ingress 用 WAF Policy の Resource ID"
  value       = azurerm_web_application_firewall_policy.private.id
}

output "waf_policy_public_id" {
  description = "Public Ingress 用 WAF Policy の Resource ID"
  value       = azurerm_web_application_firewall_policy.public.id
}
