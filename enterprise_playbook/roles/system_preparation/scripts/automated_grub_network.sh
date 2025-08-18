#!/bin/bash

# Configuration
AUTO_PROCEED=true
AUTO_CONFIG_METHOD=1  # 1=Automatic, 2=DHCP, 3=Manual

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Automated GRUB Network Configuration for Tang Client ===${NC}"
echo -e "Auto-proceed: ${YELLOW}$AUTO_PROCEED${NC}"
echo -e "Auto-config method: ${YELLOW}$AUTO_CONFIG_METHOD${NC} (1=Automatic, 2=DHCP)"
echo ""

# Function to detect current network configuration
detect_network_config() {
    echo -e "${BLUE}Detecting current network configuration...${NC}"

    # Get current IP configuration
    CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    CURRENT_INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\w+' | head -1)
    CURRENT_GATEWAY=$(ip route | grep default | grep "$CURRENT_INTERFACE" | awk '{print $3}' | head -1)

    # Try to determine subnet mask
    CURRENT_CIDR=$(ip addr show "$CURRENT_INTERFACE" 2>/dev/null | grep "inet $CURRENT_IP" | awk '{print $2}' | cut -d/ -f2)
    case $CURRENT_CIDR in
        24) NETMASK="255.255.255.0" ;;
        16) NETMASK="255.255.0.0" ;;
        8)  NETMASK="255.0.0.0" ;;
        *)  NETMASK="255.255.255.0" ;;  # default
    esac

    # Get DNS servers
    DNS_SERVER=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}' | head -1)
    if [ -z "$DNS_SERVER" ]; then
        DNS_SERVER="8.8.8.8"  # fallback
    fi

    echo ""
    echo -e "${CYAN}Current Network Configuration:${NC}"
    echo -e "  IP Address: ${YELLOW}$CURRENT_IP${NC}"
    echo -e "  Interface:  ${YELLOW}$CURRENT_INTERFACE${NC}"
    echo -e "  Gateway:    ${YELLOW}$CURRENT_GATEWAY${NC}"
    echo -e "  Subnet:     ${YELLOW}$NETMASK${NC} (/$CURRENT_CIDR)"
    echo -e "  DNS Server: ${YELLOW}$DNS_SERVER${NC}"
    echo ""
}

# Function to detect Tang URLs
detect_tang_urls() {
    echo -e "${BLUE}Detecting Tang server URLs from LUKS bindings...${NC}"

    TANG_URLS=()
    HTTPS_DETECTED=false

    # Find all LUKS devices and check their Tang bindings
    while IFS= read -r line; do
        if [[ "$line" == *"TYPE=\"crypto_LUKS\""* ]]; then
            device=$(echo "$line" | cut -d: -f1)
            if [ -b "$device" ]; then
                # Check for Tang bindings
                tang_info=$(sudo clevis luks list -d "$device" 2>/dev/null | grep tang)
                if [ -n "$tang_info" ]; then
                    url=$(echo "$tang_info" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
                    if [ -n "$url" ]; then
                        TANG_URLS+=("$url")
                        if [[ "$url" == "https://"* ]]; then
                            HTTPS_DETECTED=true
                        fi
                    fi
                fi
            fi
        fi
    done < <(sudo blkid)

    # Remove duplicates
    TANG_URLS=($(printf '%s\n' "${TANG_URLS[@]}" | sort -u))

    if [ ${#TANG_URLS[@]} -gt 0 ]; then
        echo -e "${GREEN}Found Tang server URLs:${NC}"
        for url in "${TANG_URLS[@]}"; do
            echo -e "  • ${YELLOW}$url${NC}"
        done
    else
        echo -e "${YELLOW}No Tang bindings detected. Using default HTTPS assumption.${NC}"
        HTTPS_DETECTED=true
    fi
    echo ""
}

# Function to show network configuration options
show_network_options() {
    echo -e "${BLUE}=== Network Configuration Options ===${NC}"
    echo ""

    echo -e "${GREEN}Option 1: Automatic Static IP (Recommended)${NC}"
    echo "  Uses your current network configuration"
    echo "  More reliable for Tang communication"

    if [ -n "$CURRENT_IP" ] && [ -n "$CURRENT_GATEWAY" ] && [ -n "$CURRENT_INTERFACE" ]; then
        if [ "$HTTPS_DETECTED" = true ]; then
            STATIC_CONFIG="ip=$CURRENT_IP::$CURRENT_GATEWAY:$NETMASK:client:$CURRENT_INTERFACE:none nameserver=$DNS_SERVER"
            echo -e "  Command: ${CYAN}$STATIC_CONFIG${NC}"
            echo -e "  ${YELLOW}Note: Includes nameserver for HTTPS Tang URLs${NC}"
        else
            STATIC_CONFIG="ip=$CURRENT_IP::$CURRENT_GATEWAY:$NETMASK:client:$CURRENT_INTERFACE:none"
            echo -e "  Command: ${CYAN}$STATIC_CONFIG${NC}"
        fi
    else
        echo -e "  ${RED}Cannot auto-detect network parameters${NC}"
        echo -e "  Template: ${CYAN}ip=YOUR_IP::YOUR_GATEWAY:255.255.255.0:client:eth0:none nameserver=8.8.8.8${NC}"
        STATIC_CONFIG=""
    fi
    echo ""

    echo -e "${GREEN}Option 2: DHCP (Automatic IP)${NC}"
    echo "  Simple but may not work in all environments"
    echo -e "  Command: ${CYAN}ip=dhcp${NC}"
    echo ""
}

# Function to backup GRUB configuration
backup_grub_config() {
    local backup_file="/etc/default/grub.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${BLUE}Creating backup of GRUB configuration...${NC}"

    if sudo cp /etc/default/grub "$backup_file"; then
        echo -e "${GREEN}✓ Backup created: $backup_file${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to create backup${NC}"
        return 1
    fi
}

# Function to show current GRUB configuration
show_current_grub() {
    echo -e "${BLUE}Current GRUB configuration:${NC}"
    echo ""

    if [ -f /etc/default/grub ]; then
        echo -e "${CYAN}GRUB_CMDLINE_LINUX setting:${NC}"
        grep "^GRUB_CMDLINE_LINUX" /etc/default/grub || echo "  (not set or commented out)"
    else
        echo -e "${RED}GRUB configuration file not found!${NC}"
        return 1
    fi
    echo ""
}

# Function to configure GRUB automatically
configure_grub_auto() {
    local network_config="$1"

    echo -e "${BLUE}Configuring GRUB automatically...${NC}"

    # Backup first
    if ! backup_grub_config; then
        return 1
    fi

    # Check if GRUB_CMDLINE_LINUX exists
    if grep -q "^GRUB_CMDLINE_LINUX" /etc/default/grub; then
        # Update existing line
        sudo sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"$network_config\"/" /etc/default/grub
    else
        # Add new line
        echo "GRUB_CMDLINE_LINUX=\"$network_config\"" | sudo tee -a /etc/default/grub > /dev/null
    fi

    echo -e "${GREEN}✓ GRUB configuration updated${NC}"

    # Show what was configured
    echo ""
    echo -e "${CYAN}New GRUB configuration:${NC}"
    grep "^GRUB_CMDLINE_LINUX" /etc/default/grub
    echo ""
}

# Function to update GRUB
update_grub() {
    echo -e "${BLUE}Updating GRUB...${NC}"

    if sudo update-grub; then
        echo -e "${GREEN}✓ GRUB updated successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to update GRUB${NC}"
        return 1
    fi
}

# Function to test Tang connectivity
test_tang_connectivity() {
    echo -e "${BLUE}Testing Tang server connectivity...${NC}"

    if [ ${#TANG_URLS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No Tang URLs detected, skipping connectivity test${NC}"
        return
    fi

    for url in "${TANG_URLS[@]}"; do
        echo -n "Testing $url... "
        if curl -s --connect-timeout 5 "$url/adv" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Reachable${NC}"
        else
            echo -e "${RED}✗ Unreachable${NC}"
            echo -e "  ${YELLOW}Warning: Tang server may not be accessible during boot${NC}"
        fi
    done
    echo ""
}

# Function to show final instructions
show_final_instructions() {
    echo -e "${BLUE}=== Final Instructions ===${NC}"
    echo ""
    echo -e "${GREEN}Configuration Complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Test current configuration:"
    echo "   • Verify Tang connectivity (done above)"
    echo "   • Check GRUB syntax: sudo grub-mkconfig -o /dev/null"
    echo ""
    echo "2. Reboot to test automatic unlocking:"
    echo "   sudo reboot"
    echo ""
    echo -e "${YELLOW}During boot:${NC}"
    echo "• System will configure network using GRUB settings"
    echo "• Clevis will attempt to contact Tang server(s)"
    echo "• If successful, encrypted drives will unlock automatically"
    echo "• If Tang is unreachable, system will prompt for passwords"
    echo ""
    echo -e "${CYAN}Troubleshooting commands (after boot):${NC}"
    echo "• Check boot logs: sudo journalctl -b | grep -i clevis"
    echo "• Check network: sudo journalctl -b | grep -i network"
    echo "• Test Tang: curl [tang-url]/adv"
    echo "• Manual unlock: sudo clevis luks unlock -d /dev/[device]"
    echo ""
    echo -e "${RED}Important:${NC} Keep your LUKS passphrases as backup!"
    echo ""
    echo -e "${GREEN}Automated GRUB configuration completed successfully!${NC}"
}

# Function for automated configuration (no user input)
automated_config() {
    echo -e "${BLUE}=== Starting Automated Configuration ===${NC}"
    echo -e "Selected method: ${YELLOW}$AUTO_CONFIG_METHOD${NC}"
    echo ""

    case $AUTO_CONFIG_METHOD in
        1)
            if [ -n "$STATIC_CONFIG" ]; then
                echo -e "${GREEN}Applying automatic static IP configuration...${NC}"
                echo -e "Configuration: ${CYAN}$STATIC_CONFIG${NC}"
                configure_grub_auto "$STATIC_CONFIG"
                update_grub
            else
                echo -e "${RED}Cannot auto-detect network configuration${NC}"
                echo -e "${YELLOW}Falling back to DHCP...${NC}"
                configure_grub_auto "ip=dhcp"
                update_grub
            fi
            ;;
        2)
            echo -e "${GREEN}Applying DHCP configuration...${NC}"
            echo -e "Configuration: ${CYAN}ip=dhcp${NC}"
            configure_grub_auto "ip=dhcp"
            update_grub
            ;;
        *)
            echo -e "${RED}Invalid AUTO_CONFIG_METHOD: $AUTO_CONFIG_METHOD${NC}"
            echo -e "${YELLOW}Falling back to DHCP...${NC}"
            configure_grub_auto "ip=dhcp"
            update_grub
            ;;
    esac
}

# Function for interactive configuration (fallback)
interactive_config() {
    echo -e "${YELLOW}Choose configuration method:${NC}"
    echo "1. Automatic (recommended) - Use detected network settings"
    echo "2. DHCP - Simple automatic IP assignment"
    echo "3. Manual - Enter custom network settings"
    echo "4. Show current config only (no changes)"
    echo ""

    while true; do
        read -p "Enter choice (1-4): " choice
        case $choice in
            1)
                if [ -n "$STATIC_CONFIG" ]; then
                    configure_grub_auto "$STATIC_CONFIG"
                    update_grub
                else
                    echo -e "${RED}Cannot auto-detect network configuration${NC}"
                    continue
                fi
                break
                ;;
            2)
                configure_grub_auto "ip=dhcp"
                update_grub
                break
                ;;
            3)
                echo ""
                echo "Enter network configuration parameters:"
                read -p "IP Address: " manual_ip
                read -p "Gateway: " manual_gateway
                read -p "Netmask (default: 255.255.255.0): " manual_netmask
                read -p "Interface (default: eth0): " manual_interface

                manual_netmask=${manual_netmask:-255.255.255.0}
                manual_interface=${manual_interface:-eth0}

                if [ "$HTTPS_DETECTED" = true ]; then
                    read -p "DNS Server (default: 8.8.8.8): " manual_dns
                    manual_dns=${manual_dns:-8.8.8.8}
                    manual_config="ip=$manual_ip::$manual_gateway:$manual_netmask:client:$manual_interface:none nameserver=$manual_dns"
                else
                    manual_config="ip=$manual_ip::$manual_gateway:$manual_netmask:client:$manual_interface:none"
                fi

                configure_grub_auto "$manual_config"
                update_grub
                break
                ;;
            4)
                echo -e "${GREEN}Current configuration displayed above.${NC}"
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, 3, or 4."
                ;;
        esac
    done
}

# Main execution
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script requires root privileges.${NC}"
        echo "Please run with sudo: sudo $0"
        exit 1
    fi

    # Check if GRUB exists
    if [ ! -f /etc/default/grub ]; then
        echo -e "${RED}GRUB configuration file not found!${NC}"
        echo "This system may not use GRUB as bootloader."
        exit 1
    fi

    # Detect network configuration
    detect_network_config

    # Detect Tang URLs
    detect_tang_urls

    # Show current GRUB config
    show_current_grub

    # Show network options
    show_network_options

    # Choose configuration method
    if [ "$AUTO_PROCEED" = true ]; then
        # Automated configuration
        automated_config
    else
        # Interactive configuration (fallback)
        interactive_config
    fi

    # Test Tang connectivity
    test_tang_connectivity

    # Show final instructions
    show_final_instructions
}

# Run main function
main "$@"

