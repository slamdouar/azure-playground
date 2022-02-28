data "azurerm_resource_group" "vm" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "vm" {
  name                = var.virtual_network_name
  resource_group_name = var.virtual_network_resource_group_name
}

data "azurerm_subnet" "vm" {
  name                 = var.virtual_network_subnet_name
  virtual_network_name = data.azurerm_virtual_network.vm.name
  resource_group_name  = data.azurerm_virtual_network.vm.resource_group_name
}

data "template_file" "ips" {
  count    = var.instance_count
  template = "$${ip}"

  vars = {
    ip             = cidrhost(data.azurerm_subnet.vm.address_prefixes[0], count.index + var.private_ip_address_start)
    hostname       = "${var.hostname}${count.index}"
    ansible_host_p = "${var.hostname}${count.index}-p"
  }
}

resource "azurerm_network_interface" "vm" {
  count                         = var.instance_count
  name                          = "nic-${var.name}${count.index}"
  location                      = data.azurerm_resource_group.vm.location
  resource_group_name           = data.azurerm_resource_group.vm.name
  enable_accelerated_networking = var.enable_accelerated_networking
  enable_ip_forwarding          = var.enable_ip_forwarding

  ip_configuration {
    name                          = "nicc-${var.name}${count.index}"
    subnet_id                     = data.azurerm_subnet.vm.id
    private_ip_address_allocation = var.private_ip_address_allocation
    private_ip_address            = var.private_ip_address_allocation == "Static" ? element(data.template_file.ips.*.rendered, count.index) : ""
    public_ip_address_id          = length(azurerm_public_ip.vm.*.id) > 0 ? element(azurerm_public_ip.vm.*.id, count.index) : ""
  }
  tags = merge({ "resourcename" = format("%s", lower(replace("nic-${var.name}${count.index}", "/[[:^alnum:]]/", ""))) }, var.tags, )
}

resource "azurerm_linux_virtual_machine" "vm" {
  count                           = var.instance_count
  name                            = "${var.name}${count.index}"
  resource_group_name             = data.azurerm_resource_group.vm.name
  location                        = data.azurerm_resource_group.vm.location
  size                            = var.size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = length(var.admin_password) > 0 ? false : true

  network_interface_ids = [element(azurerm_network_interface.vm.*.id, count.index)]

  source_image_reference {
    publisher = var.source_image_reference_publisher
    offer     = var.source_image_reference_offer
    sku       = var.source_image_reference_sku
    version   = var.source_image_reference_version
  }

  os_disk {
    storage_account_type = var.os_disk_storage_account_type
    caching              = var.os_disk_caching
    disk_size_gb         = var.os_disk_size_gb

    dynamic "diff_disk_settings" {
      for_each = var.os_disk_ephemeral ? [1] : []
      content {
        option = "Local"
      }
    }
  }

  dynamic "admin_ssh_key" {
    for_each = length(var.public_key_openssh) > 0 ? [1] : []
    content {
      public_key = var.public_key_openssh
      username   = var.admin_username
    }
  }

  computer_name = "${var.hostname}${count.index}"

  custom_data = base64encode(file("${path.module}/setup/cloudinit.tpl"))


  tags = merge({ "resourcename" = format("%s", lower(replace(var.name, "/[[:^alnum:]]/", ""))) }, var.tags, )

}

# add a data disk - we were going to iterate through a collection, but this is easier for now
resource "azurerm_managed_disk" "vm_data" {
  count                = var.data_disk_size_gb != null ? var.instance_count : 0
  name                 = "${azurerm_linux_virtual_machine.vm[count.index].name}-disk-data"
  location             = data.azurerm_resource_group.vm.location
  resource_group_name  = data.azurerm_resource_group.vm.name
  storage_account_type = var.data_disk_storage_account_type
  create_option        = var.data_disk_create_option
  disk_size_gb         = var.data_disk_size_gb
  tags                 = merge({ "resourcename" = format("%s", lower(replace("${azurerm_linux_virtual_machine.vm[count.index].name}-disk-data", "/[[:^alnum:]]/", ""))) }, var.tags, )
}

resource "azurerm_virtual_machine_data_disk_attachment" "vm_data" {
  count              = var.data_disk_size_gb != null ? var.instance_count : 0
  managed_disk_id    = azurerm_managed_disk.vm_data[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.vm[count.index].id
  lun                = 1
  caching            = var.data_disk_caching
}

resource "azurerm_public_ip" "vm" {
  count               = var.public_ip ? var.instance_count : 0
  name                = "pip-${var.name}${count.index}"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = data.azurerm_resource_group.vm.location
  allocation_method   = var.public_ip_allocation_method
  domain_name_label   = var.public_ip_dns != "" ? "${var.public_ip_dns}${count.index}" : null
  tags                = merge({ "resourcename" = format("%s", lower(replace("pip-${var.name}${count.index}", "/[[:^alnum:]]/", ""))) }, var.tags, )
}

resource "azurerm_network_security_group" "vm" {
  count               = var.public_ip ? 1 : 0
  name                = "nsg-${var.name}"
  resource_group_name = data.azurerm_resource_group.vm.name
  location            = data.azurerm_resource_group.vm.location

  tags = merge({ "resourcename" = format("%s", lower(replace("nsg-${var.name}", "/[[:^alnum:]]/", ""))) }, var.tags, )
}

resource "azurerm_network_security_rule" "allow_ports" {
  count                       = var.public_ip && length(var.nsg_allowed_ports) > 0 ? length(var.nsg_allowed_ports) : 0
  name                        = "allow_remote_${element(var.nsg_allowed_ports, count.index)}_in_all"
  resource_group_name         = data.azurerm_resource_group.vm.name
  description                 = "Allow remote protocol in from all locations"
  priority                    = 101 + count.index
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = element(split("_", element(var.nsg_allowed_ports, count.index)), 0)
  source_port_range           = "*"
  destination_port_range      = element(split("_", element(var.nsg_allowed_ports, count.index)), 1)
  source_address_prefixes     = var.nsg_source_address_prefixes
  destination_address_prefix  = "*"
  network_security_group_name = azurerm_network_security_group.vm[0].name
}

resource "azurerm_network_interface_security_group_association" "test" {
  count                     = var.public_ip ? var.instance_count : 0
  network_interface_id      = azurerm_network_interface.vm[count.index].id
  network_security_group_id = azurerm_network_security_group.vm[0].id
}
