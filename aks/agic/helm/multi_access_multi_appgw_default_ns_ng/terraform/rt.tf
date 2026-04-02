# ============================================================
# Route Table — AKS subnet
# デフォルト経路 (0.0.0.0/0) を Azure Firewall に向ける
# AKS の outbound_type = "userDefinedRouting" と組み合わせて使用
# ============================================================
resource "azurerm_route_table" "aks" {
  name                = "multi-appgw-aks-rt"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_route" "aks_default" {
  name                   = "aks-default-via-firewall"
  resource_group_name    = azurerm_resource_group.rg.name
  route_table_name       = azurerm_route_table.aks.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.fw.ip_configuration[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  route_table_id = azurerm_route_table.aks.id
}
