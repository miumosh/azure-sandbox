# ============================================================
# Public IP for Test VM
# ============================================================
resource "azurerm_public_ip" "test_vm" {
  name                = "agic-test-vm-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ============================================================
# NIC for Test VM
# ============================================================
resource "azurerm_network_interface" "test_vm" {
  name                = "agic-test-vm-nic"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.test_vm.id
  }
}

# ============================================================
# Test VM (Ubuntu 22.04 LTS, vm-subnet)
# パスワード認証 / SSH 鍵なし — 検証環境のみの設定
# ============================================================
resource "azurerm_linux_virtual_machine" "test_vm" {
  name                            = "agic-test-vm"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = "Standard_B1s"
  admin_username                  = var.vm_admin_username
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.test_vm.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
