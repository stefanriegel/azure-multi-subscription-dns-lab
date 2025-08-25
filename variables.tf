variable "location" {
  description = "Azure region for resource deployment"
  type        = string
  default     = "westeurope"

  validation {
    condition = contains([
      "eastus", "eastus2", "westus", "westus2", "westus3",
      "centralus", "northcentralus", "southcentralus", "westcentralus",
      "northeurope", "westeurope", "uksouth", "ukwest",
      "francecentral", "germanywestcentral", "switzerlandnorth",
      "norwayeast", "southeastasia", "eastasia", "australiaeast",
      "australiasoutheast", "japaneast", "japanwest", "koreacentral",
      "southafricanorth", "brazilsouth", "centralindia", "southindia"
    ], var.location)
    error_message = "The location must be a valid Azure region."
  }
}

variable "prefix" {
  description = "Resource name prefix (3-6 chars, lowercase letters and numbers only)"
  type        = string
  default     = "dnslab"

  validation {
    condition     = length(var.prefix) >= 3 && length(var.prefix) <= 6 && can(regex("^[a-z0-9]+$", var.prefix))
    error_message = "Prefix must be 3-6 characters long and contain only lowercase letters and numbers."
  }
}

variable "admin_public_key" {
  description = "SSH public key for DNS server VM access"
  type        = string

  validation {
    condition     = can(regex("^ssh-rsa", var.admin_public_key))
    error_message = "Admin public key must be a valid SSH RSA public key starting with 'ssh-rsa'."
  }
}

# Network Configuration Variables
variable "hub_vnet_cidr" {
  description = "CIDR block for hub VNet (simulates on-premises network)"
  type        = string
  default     = "10.100.0.0/16"

  validation {
    condition     = can(cidrhost(var.hub_vnet_cidr, 0))
    error_message = "Hub VNet CIDR must be a valid CIDR block."
  }
}

variable "subscription_a_vnet_cidr" {
  description = "CIDR block for Subscription A VNet (first spoke network)"
  type        = string
  default     = "10.1.0.0/16"

  validation {
    condition     = can(cidrhost(var.subscription_a_vnet_cidr, 0))
    error_message = "Subscription A VNet CIDR must be a valid CIDR block."
  }
}

variable "subscription_b_vnet_cidr" {
  description = "CIDR block for Subscription B VNet (second spoke network)"
  type        = string
  default     = "10.2.0.0/16"

  validation {
    condition     = can(cidrhost(var.subscription_b_vnet_cidr, 0))
    error_message = "Subscription B VNet CIDR must be a valid CIDR block."
  }
}

# DNS Server Configuration Variables
variable "central_dns_ip" {
  description = "Static IP for central BIND9 DNS server in hub VNet"
  type        = string
  default     = "10.100.1.10"

  validation {
    condition     = can(cidrhost("10.100.0.0/16", 0)) && can(regex("^10\\.100\\.", var.central_dns_ip))
    error_message = "Central DNS IP must be within the hub VNet range (10.100.0.0/16)."
  }
}

variable "subscription_a_dns_ip" {
  description = "Static IP for Subscription A DNS resolver inbound endpoint"
  type        = string
  default     = "10.1.0.68"

  validation {
    condition     = can(cidrhost("10.1.0.0/16", 0)) && can(regex("^10\\.1\\.", var.subscription_a_dns_ip))
    error_message = "Subscription A DNS IP must be within the Subscription A VNet range (10.1.0.0/16)."
  }
}

variable "subscription_b_dns_ip" {
  description = "Static IP for Subscription B DNS resolver inbound endpoint"
  type        = string
  default     = "10.2.0.68"

  validation {
    condition     = can(cidrhost("10.2.0.0/16", 0)) && can(regex("^10\\.2\\.", var.subscription_b_dns_ip))
    error_message = "Subscription B DNS IP must be within the Subscription B VNet range (10.2.0.0/16)."
  }
}

# VM Configuration Variables
variable "dns_vm_size" {
  description = "Azure VM size for DNS server (Standard_B1s recommended for cost optimization)"
  type        = string
  default     = "Standard_B1s"

  validation {
    condition = contains([
      "Standard_B1s", "Standard_B1ls", "Standard_B2s", "Standard_B2ms",
      "Standard_D2s_v3", "Standard_D4s_v3", "Standard_DS1_v2", "Standard_DS2_v2"
    ], var.dns_vm_size)
    error_message = "DNS VM size must be a supported VM size for DNS workloads."
  }
}

# Storage Configuration Variables
variable "storage_account_tier" {
  description = "Storage account performance tier (Standard for cost, Premium for performance)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.storage_account_tier)
    error_message = "Storage account tier must be either Standard or Premium."
  }
}

variable "storage_replication_type" {
  description = "Storage account replication type (LRS recommended for lab environments)"
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.storage_replication_type)
    error_message = "Storage replication type must be one of: LRS, GRS, RAGRS, ZRS, GZRS, RAGZRS."
  }
}

variable "storage_allow_public_access" {
  description = "Allow public access to storage account blobs (false recommended for private endpoint scenarios)"
  type        = bool
  default     = false
}

variable "enable_vm_for_testing" {
  description = "Deploy test VM in on-premises VNet for DNS testing (increases costs)"
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "Admin username for test VM (if enabled)"
  type        = string
  default     = "azureuser"

  validation {
    condition     = length(var.admin_username) >= 3 && length(var.admin_username) <= 20
    error_message = "Admin username must be between 3 and 20 characters long."
  }
}

variable "tags" {
  description = "Tags to apply to all resources for cost tracking and organization"
  type        = map(string)
  default = {
    Environment = "Lab"
    Purpose     = "Multi-Subscription DNS Testing"
    Owner       = "Stefan Riegel"
    CostCenter  = "IT-Lab"
    Project     = "Azure-DNS-Challenge"
    CreatedBy   = "Terraform"
  }
}
