#!/bin/bash
# BIND9 DNS Server Setup for Azure Multi-Subscription DNS Lab
# Configures BIND9 to demonstrate DNS forwarding problem

set -e

echo "Starting BIND9 DNS server setup..."

# Update system and install BIND9
apt-get update
apt-get install -y bind9 bind9utils bind9-doc dnsutils

# Create BIND configuration that demonstrates the problem
cat > /etc/bind/named.conf.options << 'EOF'
options {
    directory "/var/cache/bind";
    
    # Listen on all interfaces
    listen-on { any; };
    listen-on-v6 { none; };
    
    # Allow queries from private networks
    allow-query { 10.0.0.0/8; 192.168.0.0/16; 172.16.0.0/12; localhost; };
    allow-recursion { 10.0.0.0/8; 192.168.0.0/16; 172.16.0.0/12; localhost; };
    
    # Problem: can only forward to ONE resolver
    # Uncomment ONE option to demonstrate the issue:
    
    # Option 1: Forward to Subscription A resolver only (Subscription B will fail)
    forwarders { ${subscription_a_resolver}; };
    
    # Option 2: Forward to Subscription B resolver only (Subscription A will fail)  
    # forwarders { ${subscription_b_resolver}; };
    
    # Option 3: Forward to both (non-deterministic results)
    # forwarders { ${subscription_a_resolver}; ${subscription_b_resolver}; };
    
    # Default Azure DNS for non-private queries
    # forwarders { 168.63.129.16; };
    
    forward only;
    
    dnssec-validation auto;
    auth-nxdomain no;    
};
EOF

# Create logging configuration
cat > /etc/bind/named.conf.logging << 'EOF'
logging {
    channel default_debug {
        file "/var/log/bind/default.log";
        severity dynamic;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    
    channel query_log {
        file "/var/log/bind/queries.log";
        severity info;
        print-time yes;
        print-category yes;
    };
    
    category default { default_debug; };
    category queries { query_log; };
};
EOF

# Create log directory
mkdir -p /var/log/bind
chown bind:bind /var/log/bind

# Include logging configuration
echo 'include "/etc/bind/named.conf.logging";' >> /etc/bind/named.conf

# Create management script for switching forwarder configurations
cat > /usr/local/bin/switch-dns-forwarder << 'EOF'
#!/bin/bash
# Switch between different forwarder configurations to demonstrate the problem

case "$1" in
    "subscription-a")
        echo "Configuring forwarder for Subscription A only..."
        sudo sed -i 's/^[[:space:]]*# forwarders.*${subscription_a_resolver}.*/    forwarders { ${subscription_a_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*forwarders.*${subscription_b_resolver}.*/    # forwarders { ${subscription_b_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*forwarders.*168.63.129.16.*/    # forwarders { 168.63.129.16; };/' /etc/bind/named.conf.options
        ;;
    "subscription-b")
        echo "Configuring forwarder for Subscription B only..."
        sudo sed -i 's/^[[:space:]]*forwarders.*${subscription_a_resolver}.*/    # forwarders { ${subscription_a_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*# forwarders.*${subscription_b_resolver}.*/    forwarders { ${subscription_b_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*forwarders.*168.63.129.16.*/    # forwarders { 168.63.129.16; };/' /etc/bind/named.conf.options
        ;;
    "both")
        echo "Configuring forwarder for both subscriptions (non-deterministic)..."
        sudo sed -i 's/^[[:space:]]*# forwarders.*${subscription_a_resolver}.*/    # forwarders { ${subscription_a_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*# forwarders.*${subscription_b_resolver}.*/    # forwarders { ${subscription_b_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*forwarders.*168.63.129.16.*/    forwarders { ${subscription_a_resolver}; ${subscription_b_resolver}; };/' /etc/bind/named.conf.options
        ;;
    "azure")
        echo "Configuring forwarder for Azure DNS only..."
        sudo sed -i 's/^[[:space:]]*forwarders.*${subscription_a_resolver}.*/    # forwarders { ${subscription_a_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*forwarders.*${subscription_b_resolver}.*/    # forwarders { ${subscription_b_resolver}; };/' /etc/bind/named.conf.options
        sudo sed -i 's/^[[:space:]]*# forwarders.*168.63.129.16.*/    forwarders { 168.63.129.16; };/' /etc/bind/named.conf.options
        ;;
    *)
        echo "Usage: $0 {subscription-a|subscription-b|both|azure}"
        echo ""
        echo "subscription-a  - Forward only to Subscription A resolver (${subscription_a_resolver})"
        echo "subscription-b  - Forward only to Subscription B resolver (${subscription_b_resolver})"
        echo "both            - Forward to both resolvers (non-deterministic results)"
        echo "azure           - Forward to Azure DNS (168.63.129.16)"
        exit 1
        ;;
esac

echo "Restarting BIND9..."
sudo systemctl restart bind9
sudo systemctl status bind9 --no-pager

echo "Current forwarder configuration:"
grep -A 10 "forwarders" /etc/bind/named.conf.options
EOF

chmod +x /usr/local/bin/switch-dns-forwarder

# Create test script for DNS queries
cat > /usr/local/bin/test-dns-resolution << 'EOF'
#!/bin/bash
# Test script to demonstrate DNS resolution issues

echo "=== DNS Resolution Test ==="
echo "Testing from Central BIND9 DNS Server"
echo ""

# Get storage account names from Terraform outputs (populated after deployment)
# For now, use placeholder patterns
TENANT_A_PATTERN="*sa*.blob.core.windows.net"
TENANT_B_PATTERN="*sb*.blob.core.windows.net"

echo "Current BIND9 forwarder configuration:"
grep -A 5 "forwarders" /etc/bind/named.conf.options
echo ""

echo "Testing direct resolution to subscription resolvers..."
echo "Subscription A resolver (10.1.0.68):"
timeout 5 dig @10.1.0.68 test.blob.core.windows.net +short || echo "No response/timeout"

echo "Subscription B resolver (10.2.0.68):"
timeout 5 dig @10.2.0.68 test.blob.core.windows.net +short || echo "No response/timeout"

echo ""
echo "Testing via local forwarder (10.100.1.10):"
timeout 5 dig @10.100.1.10 test.blob.core.windows.net +short || echo "No response/timeout"

echo ""
echo "To change forwarder configuration, run:"
echo "  switch-dns-forwarder subscription-a"
echo "  switch-dns-forwarder subscription-b"  
echo "  switch-dns-forwarder both"
echo "  switch-dns-forwarder azure"
EOF

chmod +x /usr/local/bin/test-dns-resolution

# Start and enable BIND9
systemctl enable bind9
systemctl start bind9

# Configure system to use local DNS
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "BIND9 DNS server setup complete!"
echo ""
echo "Management commands:"
echo "  switch-dns-forwarder {subscription-a|subscription-b|both|azure}"
echo "  test-dns-resolution"
echo ""
echo "Log files:"
echo "  /var/log/bind/default.log"
echo "  /var/log/bind/queries.log"
echo ""
echo "Current configuration: Forwarding to Subscription A resolver (${subscription_a_resolver})"
