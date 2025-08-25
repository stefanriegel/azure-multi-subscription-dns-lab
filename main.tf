########################################
# Azure Multi-Subscription DNS Lab    #
# Hub & Spoke Architecture             #
########################################
# This lab reproduces a real customer problem:
# - Hub VNet simulates on-premises with a DNS forwarder
# - Two spoke VNets simulate different Azure subscriptions
# - Both spokes have identical private DNS zones (privatelink.blob.core.windows.net)
# - Storage accounts create name conflicts
# - Hub DNS forwarder cannot route to correct resolver

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

########################
# Locals
########################
locals {
  # Derived subnet CIDRs from VNet CIDRs
  hub_dns_subnet_cidr             = cidrsubnet(var.hub_vnet_cidr, 8, 1)             # 10.100.1.0/24
  subscription_a_workload_cidr    = cidrsubnet(var.subscription_a_vnet_cidr, 8, 1)  # 10.1.1.0/24
  subscription_a_dns_inbound_cidr = cidrsubnet(var.subscription_a_vnet_cidr, 12, 4) # 10.1.0.64/28
  subscription_b_workload_cidr    = cidrsubnet(var.subscription_b_vnet_cidr, 8, 1)  # 10.2.1.0/24
  subscription_b_dns_inbound_cidr = cidrsubnet(var.subscription_b_vnet_cidr, 12, 4) # 10.2.0.64/28

  # Common values
  private_dns_zone_name = "privatelink.blob.core.windows.net"

  # Tenant configuration maps to reduce duplication
  tenants = {
    a = {
      name             = "tenant-a"
      vnet_cidr        = var.subscription_a_vnet_cidr
      workload_cidr    = local.subscription_a_workload_cidr
      dns_inbound_cidr = local.subscription_a_dns_inbound_cidr
      dns_ip           = var.subscription_a_dns_ip
      storage_prefix   = "sa"
    }
    b = {
      name             = "tenant-b"
      vnet_cidr        = var.subscription_b_vnet_cidr
      workload_cidr    = local.subscription_b_workload_cidr
      dns_inbound_cidr = local.subscription_b_dns_inbound_cidr
      dns_ip           = var.subscription_b_dns_ip
      storage_prefix   = "sb"
    }
  }
}

########################
# Hub VNet (Simulates On-Premises)
########################
resource "azurerm_resource_group" "hub" {
  name     = "${var.prefix}-rg-hub"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.prefix}-vnet-hub"
  address_space       = [var.hub_vnet_cidr]
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  # Will be changed to custom DNS after VM creation
  dns_servers = ["168.63.129.16"]
}

resource "azurerm_subnet" "hub_dns" {
  name                 = "dns-subnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [local.hub_dns_subnet_cidr]
}

# Network Security Group for DNS Forwarder VM
resource "azurerm_network_security_group" "hub_nsg" {
  name                = "${var.prefix}-hub-nsg"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DNS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }
}

# Public IP for DNS Forwarder VM management access
resource "azurerm_public_ip" "hub_dns_pip" {
  name                = "${var.prefix}-hub-dns-pip"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Network Interface for DNS Forwarder VM
resource "azurerm_network_interface" "hub_dns_nic" {
  name                = "${var.prefix}-hub-dns-nic"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hub_dns.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.central_dns_ip
    public_ip_address_id          = azurerm_public_ip.hub_dns_pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "hub_nsg_association" {
  network_interface_id      = azurerm_network_interface.hub_dns_nic.id
  network_security_group_id = azurerm_network_security_group.hub_nsg.id
}

# Central DNS Server VM with BIND9
resource "azurerm_linux_virtual_machine" "hub_dns" {
  name                = "${var.prefix}-central-dns-vm"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  size                = var.dns_vm_size
  admin_username      = "azureuser"

  lifecycle {
    create_before_destroy = true
  }

  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.hub_dns_nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.admin_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  # Install and configure BIND9 as DNS forwarder
  custom_data = base64encode(templatefile("${path.module}/dns-forwarder-setup.sh", {
    subscription_a_resolver = var.subscription_a_dns_ip
    subscription_b_resolver = var.subscription_b_dns_ip
  }))
}

########################
# Tenant Infrastructure (A & B)
########################
resource "azurerm_resource_group" "tenant_a" {
  name     = "${var.prefix}-rg-tenant-a"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "tenant_b" {
  name     = "${var.prefix}-rg-tenant-b"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "tenant_a" {
  name                = "${var.prefix}-vnet-tenant-a"
  address_space       = [local.tenants.a.vnet_cidr]
  location            = azurerm_resource_group.tenant_a.location
  resource_group_name = azurerm_resource_group.tenant_a.name
}

resource "azurerm_virtual_network" "tenant_b" {
  name                = "${var.prefix}-vnet-tenant-b"
  address_space       = [local.tenants.b.vnet_cidr]
  location            = azurerm_resource_group.tenant_b.location
  resource_group_name = azurerm_resource_group.tenant_b.name
}

resource "azurerm_subnet" "tenant_a_workload" {
  name                 = "workload-subnet"
  resource_group_name  = azurerm_resource_group.tenant_a.name
  virtual_network_name = azurerm_virtual_network.tenant_a.name
  address_prefixes     = [local.tenants.a.workload_cidr]
}

resource "azurerm_subnet" "tenant_b_workload" {
  name                 = "workload-subnet"
  resource_group_name  = azurerm_resource_group.tenant_b.name
  virtual_network_name = azurerm_virtual_network.tenant_b.name
  address_prefixes     = [local.tenants.b.workload_cidr]
}

resource "azurerm_subnet" "tenant_a_dns_inbound" {
  name                 = "dns-inbound-subnet"
  resource_group_name  = azurerm_resource_group.tenant_a.name
  virtual_network_name = azurerm_virtual_network.tenant_a.name
  address_prefixes     = [local.tenants.a.dns_inbound_cidr]

  delegation {
    name = "dns-inbound-delegation"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "tenant_b_dns_inbound" {
  name                 = "dns-inbound-subnet"
  resource_group_name  = azurerm_resource_group.tenant_b.name
  virtual_network_name = azurerm_virtual_network.tenant_b.name
  address_prefixes     = [local.tenants.b.dns_inbound_cidr]

  delegation {
    name = "dns-inbound-delegation"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private DNS Zones for both tenants (same name - this creates the problem!)
resource "azurerm_private_dns_zone" "tenant_a_blob" {
  name                = local.private_dns_zone_name
  resource_group_name = azurerm_resource_group.tenant_a.name
}

resource "azurerm_private_dns_zone" "tenant_b_blob" {
  name                = local.private_dns_zone_name
  resource_group_name = azurerm_resource_group.tenant_b.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "tenant_a_blob_link" {
  name                  = "tenant-a-blob-link"
  resource_group_name   = azurerm_resource_group.tenant_a.name
  private_dns_zone_name = azurerm_private_dns_zone.tenant_a_blob.name
  virtual_network_id    = azurerm_virtual_network.tenant_a.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "tenant_b_blob_link" {
  name                  = "tenant-b-blob-link"
  resource_group_name   = azurerm_resource_group.tenant_b.name
  private_dns_zone_name = azurerm_private_dns_zone.tenant_b_blob.name
  virtual_network_id    = azurerm_virtual_network.tenant_b.id
  registration_enabled  = false
}

# Storage Accounts for both tenants
resource "random_string" "tenant_a_sa" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "random_string" "tenant_b_sa" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "azurerm_storage_account" "tenant_a" {
  name                            = "${var.prefix}${local.tenants.a.storage_prefix}${random_string.tenant_a_sa.result}"
  resource_group_name             = azurerm_resource_group.tenant_a.name
  location                        = azurerm_resource_group.tenant_a.location
  account_tier                    = var.storage_account_tier
  account_replication_type        = var.storage_replication_type
  allow_nested_items_to_be_public = var.storage_allow_public_access
  public_network_access_enabled   = var.storage_allow_public_access

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_storage_account" "tenant_b" {
  name                            = "${var.prefix}${local.tenants.b.storage_prefix}${random_string.tenant_b_sa.result}"
  resource_group_name             = azurerm_resource_group.tenant_b.name
  location                        = azurerm_resource_group.tenant_b.location
  account_tier                    = var.storage_account_tier
  account_replication_type        = var.storage_replication_type
  allow_nested_items_to_be_public = var.storage_allow_public_access
  public_network_access_enabled   = var.storage_allow_public_access

  lifecycle {
    create_before_destroy = true
  }
}

# Private Endpoints for both tenants
resource "azurerm_private_endpoint" "tenant_a_blob_pe" {
  name                = "${var.prefix}-tenant-a-blob-pe"
  location            = azurerm_resource_group.tenant_a.location
  resource_group_name = azurerm_resource_group.tenant_a.name
  subnet_id           = azurerm_subnet.tenant_a_workload.id

  private_service_connection {
    name                           = "tenant-a-blob"
    private_connection_resource_id = azurerm_storage_account.tenant_a.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "tenant-a-blob-pe-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.tenant_a_blob.id]
  }
}

resource "azurerm_private_endpoint" "tenant_b_blob_pe" {
  name                = "${var.prefix}-tenant-b-blob-pe"
  location            = azurerm_resource_group.tenant_b.location
  resource_group_name = azurerm_resource_group.tenant_b.name
  subnet_id           = azurerm_subnet.tenant_b_workload.id

  private_service_connection {
    name                           = "tenant-b-blob"
    private_connection_resource_id = azurerm_storage_account.tenant_b.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "tenant-b-blob-pe-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.tenant_b_blob.id]
  }
}

# Private DNS Resolvers for both tenants
resource "azurerm_private_dns_resolver" "tenant_a" {
  name                = "${var.prefix}-resolver-tenant-a"
  location            = azurerm_resource_group.tenant_a.location
  resource_group_name = azurerm_resource_group.tenant_a.name
  virtual_network_id  = azurerm_virtual_network.tenant_a.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_private_dns_resolver" "tenant_b" {
  name                = "${var.prefix}-resolver-tenant-b"
  location            = azurerm_resource_group.tenant_b.location
  resource_group_name = azurerm_resource_group.tenant_b.name
  virtual_network_id  = azurerm_virtual_network.tenant_b.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "tenant_a" {
  name                    = "${var.prefix}-inbound-tenant-a"
  location                = azurerm_resource_group.tenant_a.location
  private_dns_resolver_id = azurerm_private_dns_resolver.tenant_a.id

  ip_configurations {
    private_ip_allocation_method = "Static"
    private_ip_address           = local.tenants.a.dns_ip
    subnet_id                    = azurerm_subnet.tenant_a_dns_inbound.id
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "tenant_b" {
  name                    = "${var.prefix}-inbound-tenant-b"
  location                = azurerm_resource_group.tenant_b.location
  private_dns_resolver_id = azurerm_private_dns_resolver.tenant_b.id

  ip_configurations {
    private_ip_allocation_method = "Static"
    private_ip_address           = local.tenants.b.dns_ip
    subnet_id                    = azurerm_subnet.tenant_b_dns_inbound.id
  }

  lifecycle {
    create_before_destroy = true
  }
}

########################
# VNet Peerings (Hub & Spoke)
########################
# Hub to Tenant A
resource "azurerm_virtual_network_peering" "hub_to_tenant_a" {
  name                      = "hub-to-tenant-a"
  resource_group_name       = azurerm_resource_group.hub.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.tenant_a.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
}

resource "azurerm_virtual_network_peering" "tenant_a_to_hub" {
  name                      = "tenant-a-to-hub"
  resource_group_name       = azurerm_resource_group.tenant_a.name
  virtual_network_name      = azurerm_virtual_network.tenant_a.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
  use_remote_gateways       = false
}

# Hub to Tenant B
resource "azurerm_virtual_network_peering" "hub_to_tenant_b" {
  name                      = "hub-to-tenant-b"
  resource_group_name       = azurerm_resource_group.hub.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.tenant_b.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
}

resource "azurerm_virtual_network_peering" "tenant_b_to_hub" {
  name                      = "tenant-b-to-hub"
  resource_group_name       = azurerm_resource_group.tenant_b.name
  virtual_network_name      = azurerm_virtual_network.tenant_b.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
  use_remote_gateways       = false
}

########################
# Outputs
########################
output "problem_description" {
  value = <<-EOT
    AZURE MULTI-TENANT DNS PROBLEM REPRODUCTION:
    
    Both Tenant-A and Tenant-B have identical private DNS zones:
    - ${local.private_dns_zone_name}
    
    Storage Accounts:
    - Tenant-A: ${azurerm_storage_account.tenant_a.name}.blob.core.windows.net
    - Tenant-B: ${azurerm_storage_account.tenant_b.name}.blob.core.windows.net
    
    DNS Resolver Endpoints:
    - Tenant-A Resolver: ${local.tenants.a.dns_ip}
    - Tenant-B Resolver: ${local.tenants.b.dns_ip}
    
    Central DNS Server: ${var.central_dns_ip} (BIND9)
  EOT
}

output "hub_dns_forwarder_ssh" {
  value = "ssh azureuser@${azurerm_public_ip.hub_dns_pip.ip_address}"
}

output "test_commands" {
  value = {
    # Direct queries to each resolver (should work)
    direct_test_tenant_a = "dig @${local.tenants.a.dns_ip} ${azurerm_storage_account.tenant_a.name}.blob.core.windows.net"
    direct_test_tenant_b = "dig @${local.tenants.b.dns_ip} ${azurerm_storage_account.tenant_b.name}.blob.core.windows.net"

    # Cross-tenant queries (should fail with NXDOMAIN)
    cross_test_a_to_b = "dig @${local.tenants.a.dns_ip} ${azurerm_storage_account.tenant_b.name}.blob.core.windows.net"
    cross_test_b_to_a = "dig @${local.tenants.b.dns_ip} ${azurerm_storage_account.tenant_a.name}.blob.core.windows.net"

    # Queries via hub DNS forwarder (problematic - will depend on configuration)
    hub_test_tenant_a = "dig @${var.central_dns_ip} ${azurerm_storage_account.tenant_a.name}.blob.core.windows.net"
    hub_test_tenant_b = "dig @${var.central_dns_ip} ${azurerm_storage_account.tenant_b.name}.blob.core.windows.net"
  }
}

output "tenant_a_storage_fqdn" {
  value = "${azurerm_storage_account.tenant_a.name}.blob.core.windows.net"
}

output "tenant_b_storage_fqdn" {
  value = "${azurerm_storage_account.tenant_b.name}.blob.core.windows.net"
}

output "solution_approaches" {
  value = <<-EOT
    SOLUTION APPROACHES:
    
    1. CoreDNS with selective forwarding:
       - Forward *.${local.tenants.a.storage_prefix}*.blob.core.windows.net to ${local.tenants.a.dns_ip}
       - Forward *.${local.tenants.b.storage_prefix}*.blob.core.windows.net to ${local.tenants.b.dns_ip}
       
    2. Infoblox selective forwarders:
       - Create conditional forwarders per storage account
       - Use DNS views or extensible attributes for automation
       
    3. DNS Response Policy Zones (RPZ):
       - Route specific FQDNs to specific resolvers
    
    The key is having granular control over which resolver handles each specific FQDN.
  EOT
}
