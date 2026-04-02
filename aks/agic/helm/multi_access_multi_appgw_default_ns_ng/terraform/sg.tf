# ============================================================
# NSG — AKS subnet
# ============================================================
resource "azurerm_network_security_group" "aks" {
  name                = "multi-appgw-aks-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# CNI Overlay required rules
resource "azurerm_network_security_rule" "aks_allow_node_to_node" {
  name                        = "AllowNodeToNode"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.2.3.0/24"
  destination_address_prefix  = "10.2.3.0/24"
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
  source_address_prefix       = "10.2.3.0/24"
  destination_address_prefix  = "192.168.0.0/16"
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
  source_address_prefix       = "192.168.0.0/16"
  destination_address_prefix  = "192.168.0.0/16"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# Private AppGW → AKS ノード (NodePort + ヘルスプローブ)
resource "azurerm_network_security_rule" "aks_allow_private_appgw" {
  name                        = "AllowPrivateAppGWToNodes"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1-65535"
  source_address_prefix       = "10.2.1.0/24"
  destination_address_prefix  = "10.2.3.0/24"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# Public AppGW → AKS ノード (NodePort + ヘルスプローブ)
resource "azurerm_network_security_rule" "aks_allow_public_appgw" {
  name                        = "AllowPublicAppGWToNodes"
  priority                    = 140
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1-65535"
  source_address_prefix       = "10.2.2.0/24"
  destination_address_prefix  = "10.2.3.0/24"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# ============================================================
# NSG — Private AppGW subnet
# ============================================================
resource "azurerm_network_security_group" "appgw_private" {
  name                = "multi-appgw-private-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "appgw_private" {
  subnet_id                 = azurerm_subnet.appgw_private.id
  network_security_group_id = azurerm_network_security_group.appgw_private.id
}

# AppGW v2 必須 — Azure インフラヘルスプローブ
# depends_on: destroy 時に AppGW より先にこのルールが削除されるのを防ぐ
resource "azurerm_network_security_rule" "appgw_private_allow_gw_manager" {
  name                        = "AllowGatewayManager"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.appgw_private.name

  depends_on = [azurerm_application_gateway.private]
}

# AppGW v2 必須 — Azure Load Balancer ヘルスプローブ
resource "azurerm_network_security_rule" "appgw_private_allow_lb" {
  name                        = "AllowAzureLoadBalancer"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.appgw_private.name
}

# Hub VNet の VM からの HTTP アクセス (オンプレ想定)
resource "azurerm_network_security_rule" "appgw_private_allow_vm" {
  name                        = "AllowVMSubnetHTTP"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "10.1.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.appgw_private.name
}

# ============================================================
# NSG — Public AppGW subnet
# ============================================================
resource "azurerm_network_security_group" "appgw_public" {
  name                = "multi-appgw-public-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "appgw_public" {
  subnet_id                 = azurerm_subnet.appgw_public.id
  network_security_group_id = azurerm_network_security_group.appgw_public.id
}

# depends_on: destroy 時に AppGW より先にこのルールが削除されるのを防ぐ
resource "azurerm_network_security_rule" "appgw_public_allow_gw_manager" {
  name                        = "AllowGatewayManager"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.appgw_public.name

  depends_on = [azurerm_application_gateway.public]
}

resource "azurerm_network_security_rule" "appgw_public_allow_lb" {
  name                        = "AllowAzureLoadBalancer"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.appgw_public.name
}

# インターネットからの HTTP アクセス (顧客アクセス想定)
resource "azurerm_network_security_rule" "appgw_public_allow_internet" {
  name                        = "AllowInternetHTTP"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.appgw_public.name
}

# ============================================================
# NSG — VM subnet (Hub)
# ============================================================
resource "azurerm_network_security_group" "vm" {
  name                = "multi-appgw-vm-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_network_security_rule" "vm_allow_ssh" {
  name                        = "AllowSSHFromMyIP"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.my_public_ip
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vm.name
}
