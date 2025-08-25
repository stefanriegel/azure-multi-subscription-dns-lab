#!/bin/bash
# Azure Multi-Subscription DNS Lab - Deployment Script
# ===================================================

set -e

echo "Azure Multi-Subscription DNS Lab - Deployment Script"
echo "===================================================="
echo ""

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    echo "Error: terraform.tfvars file not found!"
    echo ""
    echo "Please create terraform.tfvars by copying terraform.tfvars.example:"
    echo "  cp terraform.tfvars.example terraform.tfvars"
    echo ""
    echo "Then edit terraform.tfvars with your SSH public key and other settings."
    exit 1
fi

# Check if admin_public_key is set
if grep -q "YOUR_PUBLIC_KEY_HERE" terraform.tfvars; then
    echo "Error: Please update admin_public_key in terraform.tfvars with your actual SSH public key!"
    exit 1
fi

echo "Configuration files found and validated"
echo ""

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Plan deployment
echo ""
echo "Planning deployment..."
terraform plan -var-file=terraform.tfvars

echo ""
echo "IMPORTANT: Review the plan above carefully!"
echo ""
read -p "Do you want to proceed with deployment? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deploying infrastructure..."
    terraform apply -var-file=terraform.tfvars
    
    echo ""
    echo "Deployment completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Use the SSH command from the output to connect to the DNS server"
    echo "2. Run the test commands to demonstrate the DNS problem"
    echo "3. Use switch-dns-forwarder to test different configurations"
    echo ""
    echo "Remember to destroy when done:"
    echo "   terraform destroy -var-file=terraform.tfvars"
else
    echo "Deployment cancelled"
    exit 0
fi
