# Azure Multi-Subscription DNS Lab

## Overview

This lab reproduces a real-world Azure multi-subscription DNS problem where identical private DNS zone names across different subscriptions create routing conflicts that cannot be resolved with traditional DNS forwarding.

The challenge demonstrates why organizations need selective DNS forwarding solutions when operating across multiple Azure subscriptions.

## Quick Start

### Prerequisites

- Azure subscription with contributor access
- Terraform installed (version >= 1.5.0)
- SSH key pair for VM access

### 1. Generate SSH Key

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/azure-dns-lab
```

### 2. Configure Lab Settings

```bash
# Copy the example configuration
cp terraform.tfvars.example terraform.tfvars

# Edit with your SSH public key
nano terraform.tfvars
# Replace admin_public_key with your actual SSH public key
```

### 3. Deploy Infrastructure

```bash
# Use the automated deployment script (recommended)
./deploy.sh

# Or deploy manually
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

### 4. Connect to DNS Server

```bash
# Use the SSH command from the output
ssh -i ~/.ssh/azure-dns-lab azureuser@<PUBLIC_IP>
```

### 5. Test the DNS Problem

On the DNS server VM, run these tests to demonstrate the issue:

```bash
# Test direct resolution (should work)
dig @10.1.0.68 dnslabsa<random>.blob.core.windows.net
dig @10.2.0.68 dnslabsb<random>.blob.core.windows.net

# Test cross-tenant resolution (should fail)
dig @10.1.0.68 dnslabsb<random>.blob.core.windows.net
dig @10.2.0.68 dnslabsa<random>.blob.core.windows.net

# Test via hub DNS forwarder (problematic)
dig @10.100.1.10 dnslabsa<random>.blob.core.windows.net
dig @10.100.1.10 dnslabsb<random>.blob.core.windows.net
```

## Configuration Options

All settings are in `terraform.tfvars`:

- **location**: Azure region (default: westeurope)
- **prefix**: Resource name prefix (3-6 chars, default: dnslab)
- **admin_public_key**: Your SSH public key (required)
- **Network CIDRs**: Usually no changes needed
- **DNS IPs**: Usually no changes needed
- **VM size**: DNS server size (default: Standard_B1s)
- **tags**: Resource tags for cost tracking

## Cost Estimate

- **Private DNS Resolvers**: ~€40/month each (2 total = €80/month)
- **VM (Standard_B1s)**: ~€13/month
- **Storage & Networking**: ~€2/month
- **Total**: ~€95/month

**Important**: Remember to destroy when done: `terraform destroy -var-file=terraform.tfvars`

## Lab Architecture

```
Azure Subscription (Lab Environment)
├── Hub VNet (10.100.0.0/16)
│   └── BIND9 DNS Server (10.100.1.10)
├── Subscription A Simulation (10.1.0.0/16)
│   ├── Private DNS Zone: privatelink.blob.core.windows.net
│   ├── Storage Account: dnslabsa<random>
│   └── DNS Resolver: 10.1.0.68
└── Subscription B Simulation (10.2.0.0/16)
    ├── Private DNS Zone: privatelink.blob.core.windows.net (SAME NAME!)
    ├── Storage Account: dnslabsb<random>
    └── DNS Resolver: 10.2.0.68
```

## The Problem

The BIND9 server can only forward to ONE resolver, but both subscriptions have the same DNS zone name! This creates a fundamental routing conflict that cannot be resolved with traditional DNS forwarding.

When you configure the forwarder to use only Subscription A resolver, Subscription B names fail. When you configure it to use only Subscription B resolver, Subscription A names fail. Using both resolvers results in random/inconsistent results.

## Learning Objectives

- Understand Azure Private DNS Resolver limitations
- Experience real-world multi-subscription DNS challenges
- Learn about DNS forwarding constraints
- Explore potential solutions (CoreDNS, Infoblox, RPZ)

## Troubleshooting

### Common Issues

1. **SSH Key Error**: Make sure `admin_public_key` in `terraform.tfvars` is your actual public key
2. **Region Availability**: Some regions don't support all features, try `westeurope` or `eastus`
3. **Name Conflicts**: The prefix + random suffix should prevent this
4. **Provider Issues**: Run `terraform init` if you get provider errors

### Terraform Commands

```bash
# Check current state
terraform show

# Get specific outputs
terraform output -var-file=terraform.tfvars

# Refresh state
terraform refresh -var-file=terraform.tfvars

# Format configuration
terraform fmt

# Validate configuration
terraform validate
```

## Project Structure

```
azure-multi-subscription-dns-lab/
├── main.tf                 # Main Terraform configuration
├── variables.tf            # Variable definitions with validation
├── terraform.tfvars.example # Example configuration file
├── deploy.sh               # Automated deployment script
├── dns-forwarder-setup.sh  # BIND9 configuration script
├── .gitignore              # Git ignore rules
└── README.md               # This file
```

## Contributing

This lab is designed for educational purposes. Feel free to:

- Fork and modify for your own learning
- Submit issues or improvements
- Share with colleagues for training

## License

This project is provided as-is for educational purposes. Use at your own risk in production environments.

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Azure documentation for Private DNS Resolvers
3. Open an issue in this repository

---

**Note**: This infrastructure creates real Azure resources that incur costs. Always destroy resources when you're done testing.
