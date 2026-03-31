# ============================================================
# NSG — AKS subnet
# ============================================================
resource "azurerm_network_security_group" "aks" {
  name                = "agic-green-aks-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# CNI Overlay required rules (ref: memo/ai_order.md §3-4)
resource "azurerm_network_security_rule" "aks_allow_node_to_node" {
  name                        = "AllowNodeToNode"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.0.2.0/24" # aks-subnet
  destination_address_prefix  = "10.0.2.0/24" # aks-subnet
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_allow_node_to_pod" {
  name                        = "AllowNodeToPod"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.0.2.0/24"   # aks-subnet
  destination_address_prefix  = "192.168.0.0/16" # pod CIDR (CNI Overlay)
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_allow_pod_to_pod" {
  name                        = "AllowPodToPod"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "192.168.0.0/16" # pod CIDR
  destination_address_prefix  = "192.168.0.0/16" # pod CIDR
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_allow_appgw_to_nodes" {
  name                        = "AllowAppGWToNodes"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "30000-32767" # NodePort range
  source_address_prefix       = "10.0.1.0/24" # appgw-subnet
  destination_address_prefix  = "10.0.2.0/24" # aks-subnet
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# ============================================================
# NSG — VM subnet
# ============================================================
resource "azurerm_network_security_group" "vm" {
  name                = "agic-green-vm-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# SSH を自分のグローバル IP のみに限定
# 事前に scripts/update_my_ip.sh を実行して terraform.tfvars を更新すること
resource "azurerm_network_security_rule" "vm_allow_ssh" {
  name                        = "AllowSSHFromMyIP"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.my_public_ip # e.g. "203.0.113.1/32"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vm.name
}
