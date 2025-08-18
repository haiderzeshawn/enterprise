#!/bin/bash

# Configuration
TANG_URL="http://192.168.44.98:7500"
LUKS_PASSPHRASE="VW@e(n@VM@R2R2"
AUTO_PROCEED=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Automated Tang LUKS Binding Script ===${NC}"
echo -e "Tang server URL: ${YELLOW}$TANG_URL${NC}"
echo -e "Auto-proceed: ${YELLOW}$AUTO_PROCEED${NC}"
echo ""

# Function to detect LUKS drives
detect_luks_drives() {
    echo -e "${BLUE}Detecting LUKS encrypted drives...${NC}"

    # Get all block devices with crypto_LUKS filesystem
    # Use multiple methods to ensure we get clean device names
    LUKS_DRIVES=()

    # Method 1: Use blkid to find LUKS devices
    while IFS= read -r line; do
        if [[ "$line" == *"TYPE=\"crypto_LUKS\""* ]]; then
            device=$(echo "$line" | cut -d: -f1)
            LUKS_DRIVES+=("$device")
        fi
    done < <(sudo blkid)

    # Method 2: Fallback - parse lsblk output more carefully
    if [ ${#LUKS_DRIVES[@]} -eq 0 ]; then
        while IFS= read -r line; do
            # Remove tree characters and extract device name
            clean_name=$(echo "$line" | sed 's/[├└│─ ]*//g' | awk '{print $1}')
            if [[ "$line" == *"crypto_LUKS"* ]] && [[ -n "$clean_name" ]]; then
                LUKS_DRIVES+=("/dev/$clean_name")
            fi
        done < <(lsblk -f -n -o NAME,FSTYPE)
    fi

    # Remove duplicates and validate devices
    LUKS_DRIVES=($(printf '%s\n' "${LUKS_DRIVES[@]}" | sort -u))

    # Filter out non-existent devices
    VALID_DRIVES=()
    for drive in "${LUKS_DRIVES[@]}"; do
        if [ -b "$drive" ] && cryptsetup isLuks "$drive" 2>/dev/null; then
            VALID_DRIVES+=("$drive")
        fi
    done
    LUKS_DRIVES=("${VALID_DRIVES[@]}")

    if [ ${#LUKS_DRIVES[@]} -eq 0 ]; then
        echo -e "${RED}✗ No LUKS encrypted drives found!${NC}"
        echo "Debug: Checking for LUKS devices manually..."
        echo "Available block devices:"
        lsblk -f
        echo ""
        echo "LUKS devices found by blkid:"
        sudo blkid | grep crypto_LUKS || echo "None found"
        exit 1
    fi

    echo -e "${GREEN}Found ${#LUKS_DRIVES[@]} LUKS encrypted drives:${NC}"
    for i in "${!LUKS_DRIVES[@]}"; do
        drive="${LUKS_DRIVES[$i]}"
        # Get partition label/name if available
        label=$(lsblk -n -o PARTLABEL "$drive" 2>/dev/null | tr -d ' ' || echo "")
        uuid=$(lsblk -n -o UUID "$drive" 2>/dev/null | tr -d ' ' || echo "")
        size=$(lsblk -n -o SIZE "$drive" 2>/dev/null | tr -d ' ' || echo "")

        if [ -n "$label" ]; then
            echo -e "  $((i+1)). $drive (${YELLOW}$label${NC}) - $size"
        elif [ -n "$uuid" ]; then
            echo -e "  $((i+1)). $drive (${YELLOW}UUID: ${uuid:0:8}...${NC}) - $size"
        else
            echo -e "  $((i+1)). $drive - $size"
        fi
    done
    echo ""
}

# Function to check if Tang server is reachable
check_tang_server() {
    echo -e "${BLUE}Testing Tang server connectivity...${NC}"

    if curl -s --connect-timeout 5 "$TANG_URL/adv" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Tang server is reachable at $TANG_URL${NC}"
        return 0
    else
        echo -e "${RED}✗ Tang server is not reachable at $TANG_URL${NC}"
        echo "Please ensure:"
        echo "  - Tang server is running"
        echo "  - Network connectivity is available"
        echo "  - URL is correct"

        if [ "$AUTO_PROCEED" = true ]; then
            echo -e "${YELLOW}Auto-proceeding despite connectivity issue...${NC}"
        else
            read -p "Continue anyway? (y/N): " continue_anyway
            if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
        return 1
    fi
}

# Function to check existing Tang bindings
check_existing_bindings() {
    local drive=$1
    echo -n "  Checking existing bindings... "

    if sudo clevis luks list -d "$drive" 2>/dev/null | grep -q tang; then
        echo -e "${YELLOW}Found existing Tang binding${NC}"
        local existing_url=$(sudo clevis luks list -d "$drive" 2>/dev/null | grep tang | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
        echo "    Current Tang URL: $existing_url"

        if [ "$existing_url" = "$TANG_URL" ]; then
            echo -e "    ${GREEN}✓ Already bound to target Tang server${NC}"
            return 1  # Skip binding
        else
            if [ "$AUTO_PROCEED" = true ]; then
                echo "    Auto-replacing existing binding..."
                local slot=$(sudo clevis luks list -d "$drive" 2>/dev/null | grep tang | cut -d: -f1)
                sudo clevis luks unbind -d "$drive" -s "$slot" -f
                return 0  # Proceed with binding
            else
                read -p "    Replace existing binding? (y/N): " replace_binding
                if [[ $replace_binding =~ ^[Yy]$ ]]; then
                    echo "    Removing existing binding..."
                    local slot=$(sudo clevis luks list -d "$drive" 2>/dev/null | grep tang | cut -d: -f1)
                    sudo clevis luks unbind -d "$drive" -s "$slot" -f
                    return 0  # Proceed with binding
                else
                    return 1  # Skip binding
                fi
            fi
        fi
    else
        echo -e "${GREEN}No existing Tang bindings${NC}"
        return 0  # Proceed with binding
    fi
}

# Function to bind a single drive with automatic passphrase
bind_drive_auto() {
    local drive=$1
    local drive_name=$2

    echo -e "${BLUE}Processing: $drive${NC}"
    if [ -n "$drive_name" ]; then
        echo -e "  Label: ${YELLOW}$drive_name${NC}"
    fi

    # Check if drive exists and is a LUKS device
    if [ ! -b "$drive" ]; then
        echo -e "  ${RED}✗ Drive $drive does not exist or is not a block device${NC}"
        return 1
    fi

    if ! cryptsetup isLuks "$drive" 2>/dev/null; then
        echo -e "  ${RED}✗ Drive $drive is not a LUKS encrypted device${NC}"
        return 1
    fi

    # Check existing bindings
    if ! check_existing_bindings "$drive"; then
        echo -e "  ${YELLOW}→ Skipping $drive${NC}"
        return 0
    fi

    # Attempt to bind to Tang with automatic passphrase
    echo -e "  ${BLUE}Binding to Tang server with automatic passphrase...${NC}"

    # Install expect if not available
    if ! command -v expect >/dev/null 2>&1; then
        echo -e "  ${YELLOW}Installing expect for automated binding...${NC}"
        if command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y expect
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y expect
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y expect
        fi
    fi

    # Create temporary expect script
    local expect_script="/tmp/tang_bind_$.exp"
    cat > "$expect_script" << EOF
#!/usr/bin/expect -f
set timeout 120
set drive "$drive"
set tang_url "$TANG_URL"
set passphrase "$LUKS_PASSPHRASE"

spawn clevis luks bind -d \$drive tang "{\"url\":\"\$tang_url\"}"

expect {
    -re {Enter existing.*password.*:} {
        send "\$passphrase\r"
        exp_continue
    }
    -re {Enter existing.*passphrase.*:} {
        send "\$passphrase\r"
        exp_continue
    }
    -re {Enter.*password.*:} {
        send "\$passphrase\r"
        exp_continue
    }
    -re {Enter.*passphrase.*:} {
        send "\$passphrase\r"
        exp_continue
    }
    -re {Do you wish to trust these keys.*} {
        send "y\r"
        exp_continue
    }
    -re {Trust these keys.*} {
        send "y\r"
        exp_continue
    }
    -re {.*\[y/N\].*} {
        send "y\r"
        exp_continue
    }
    -re {.*\[Y/n\].*} {
        send "y\r"
        exp_continue
    }
    -re {.*\[yn\].*} {
        send "y\r"
        exp_continue
    }
    eof {
        catch wait result
        exit [lindex \$result 3]
    }
    timeout {
        puts "ERROR: Timeout waiting for binding"
        exit 1
    }
}
EOF

    chmod +x "$expect_script"

    # Try expect method first
    if "$expect_script"; then
        echo -e "  ${GREEN}✓ Successfully bound $drive to Tang server using expect${NC}"
        rm -f "$expect_script"
        return 0
    else
        echo -e "  ${YELLOW}Expect method failed, trying pipe method...${NC}"
        rm -f "$expect_script"

        # Fallback to pipe method
        if echo "$LUKS_PASSPHRASE" | sudo clevis luks bind -d "$drive" tang "{\"url\":\"$TANG_URL\"}"; then
            echo -e "  ${GREEN}✓ Successfully bound $drive to Tang server using pipe method${NC}"
            return 0
        else
            # Try printf method
            if printf "%s\n" "$LUKS_PASSPHRASE" | sudo clevis luks bind -d "$drive" tang "{\"url\":\"$TANG_URL\"}"; then
                echo -e "  ${GREEN}✓ Successfully bound $drive to Tang server using printf method${NC}"
                return 0
            else
                echo -e "  ${RED}✗ All binding methods failed for $drive${NC}"
                return 1
            fi
        fi
    fi
}

# Function to verify bindings
verify_bindings() {
    echo -e "${BLUE}=== Verifying Tang Bindings ===${NC}"

    local success_count=0
    local total_count=${#LUKS_DRIVES[@]}

    for drive in "${LUKS_DRIVES[@]}"; do
        echo -n "Checking $drive... "
        if sudo clevis luks list -d "$drive" 2>/dev/null | grep -q "$TANG_URL"; then
            echo -e "${GREEN}✓ Bound to Tang${NC}"
            ((success_count++))
        else
            echo -e "${RED}✗ Not bound to Tang${NC}"
        fi
    done

    echo ""
    echo -e "${BLUE}Summary: $success_count/$total_count drives successfully bound to Tang server${NC}"

    if [ $success_count -eq $total_count ]; then
        echo -e "${GREEN}✓ All drives are now bound to Tang server!${NC}"
    elif [ $success_count -gt 0 ]; then
        echo -e "${YELLOW}⚠ Some drives were not bound. Check errors above.${NC}"
    else
        echo -e "${RED}✗ No drives were bound to Tang server.${NC}"
    fi
}

# Function to show next steps
show_next_steps() {
    echo ""
    echo -e "${BLUE}=== Next Steps ===${NC}"
    echo "1. Update initramfs:"
    echo "   sudo update-initramfs -u"
    echo ""
    echo "2. Configure GRUB for network boot:"
    echo "   Edit /etc/default/grub and add network configuration"
    echo ""
    echo "3. Update GRUB:"
    echo "   sudo update-grub"
    echo ""
    echo "4. Test automatic unlocking:"
    echo "   sudo reboot"
    echo ""
    echo -e "${GREEN}Automated binding process completed successfully!${NC}"
}

# Main execution
main() {
    # Check if running as root or with sudo
    if [ "$EUID" -eq 0 ]; then
        echo -e "${YELLOW}Warning: Running as root. Some operations may not work as expected.${NC}"
        echo "Consider running with sudo instead of as root user."
        echo ""
    fi

    # Detect LUKS drives
    detect_luks_drives

    # Check Tang server connectivity
    check_tang_server

    # Auto-proceed without confirmation
    if [ "$AUTO_PROCEED" = true ]; then
        echo -e "${GREEN}Auto-proceeding with binding ${#LUKS_DRIVES[@]} drives to Tang server: $TANG_URL${NC}"
        echo -e "${YELLOW}Using automatic passphrase for binding...${NC}"
    else
        # Manual confirmation (fallback)
        echo -e "${YELLOW}Ready to bind ${#LUKS_DRIVES[@]} drives to Tang server: $TANG_URL${NC}"
        read -p "Continue? (y/N): " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            exit 0
        fi
    fi

    echo ""
    echo -e "${BLUE}=== Starting Automated Tang Binding Process ===${NC}"

    # Process each drive
    for drive in "${LUKS_DRIVES[@]}"; do
        # Get drive label/name
        label=$(lsblk -n -o PARTLABEL "$drive" 2>/dev/null || echo "")
        if [ -z "$label" ]; then
            uuid=$(lsblk -n -o UUID "$drive" 2>/dev/null || echo "")
            label="UUID: ${uuid:0:8}..."
        fi

        bind_drive_auto "$drive" "$label"
        echo ""
    done

    # Verify all bindings
    verify_bindings

    # Show next steps
    show_next_steps
}

# Run main function
main "$@"

