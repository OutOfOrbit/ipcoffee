#!/bin/bash
#
# IPCoffee - Firewall Rule Manager
# Version: 1.0.0
#
# Description:
#   A friendly script to manage UFW/iptables firewall rules
#   Because managing IP rules shouldn't be harder than brewing coffee!
#
# Usage:
#   ./ipcoffee.sh [-a|--add] [-d|--delete [--all|--number <n>|--range <start-end>]]
#
# Requirements:
#   - UFW or iptables installed
#   - Root/sudo privileges
#
# Exit Codes:
#   0 - Success
#   1 - No sudo privileges
#   2 - No firewall installed
#   3 - Operation failed

# Enable strict error handling
set -euo pipefail

# Production configuration
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Testing automation configuration
# NOTE: This variable is used for automated testing only.
# In normal production use, this remains 'none' and can be ignored.
AUTOMATION_TYPE="${IPCOFFEE_AUTO:-none}"  # Values: 'skip', 'input', or 'none'

# Create backup directory if it doesn't exist
BACKUP_DIR="./backups"
mkdir -p "$BACKUP_DIR"

# Check if we're running as root
if [[ $EUID -ne 0 ]]; then 
    echo -e "${RED}☕ Oops! Please run with sudo${NC}"
    echo "Example: sudo ./ipcoffee.sh"
    exit 1
fi

# Function to check which firewall is installed and active
check_firewall() {
    # In test mode, check what's actually installed
    if [ "$AUTOMATION_TYPE" = "skip" ]; then
        if command -v ufw >/dev/null 2>&1; then
            echo "ufw"
        elif command -v iptables >/dev/null 2>&1; then
            echo "iptables"
        else
            echo "none"
        fi
        return 0
    fi

    # Check for UFW first (preferred)
    if command -v ufw >/dev/null 2>&1; then
        # Try to get UFW status
        if sudo ufw status >/dev/null 2>&1; then
            # Check if it's the active firewall
            if systemctl is-active ufw >/dev/null 2>&1 || \
               service ufw status >/dev/null 2>&1 || \
               sudo ufw status | grep -q "Status: active"; then
                echo "ufw"
                return 0
            fi
        fi
    fi

    # Check for iptables
    if command -v iptables >/dev/null 2>&1; then
        # Try to list rules
        if sudo iptables -L >/dev/null 2>&1; then
            # Check if it's being managed by another service
            if systemctl is-active firewalld >/dev/null 2>&1; then
                echo -e "${YELLOW}Warning: firewalld is active. Using iptables directly may cause conflicts.${NC}" >&2
            fi
            echo "iptables"
            return 0
        fi
    fi

    # No supported firewall found
    echo "none"
    return 0
}

# Verify firewall is properly set up
verify_firewall_setup() {
    echo -e "\n${YELLOW}☕ Checking firewall setup...${NC}"
    local firewall_type=$(check_firewall)
    
    # Check for firewall software
    echo -n "Checking firewall software... "
    if [ "$firewall_type" = "none" ]; then
        echo -e "${RED}Not found!${NC}"
        echo -e "\n${RED}☹️ No supported firewall found!${NC}"
        echo "Please install either ufw or iptables first."
        echo
        echo "For Ubuntu/Debian:"
        echo "  sudo apt update"
        echo "  sudo apt install ufw"
        echo
        echo "For CentOS/RHEL:"
        echo "  sudo yum install iptables-services"
        echo
        exit 2
    fi
    echo -e "${GREEN}Found $firewall_type${NC}"
    
    # Check firewall status
    echo -n "Checking firewall status... "
    if [ "$firewall_type" = "ufw" ]; then
        if ! sudo ufw status >/dev/null 2>&1; then
            echo -e "${RED}Error${NC}"
            echo -e "\n${RED}Cannot access UFW status. Are you running with sudo?${NC}"
            exit 1
        fi
        
        local status=$(sudo ufw status | grep "Status:" | awk '{print $2}')
        if [ "$status" != "active" ]; then
            echo -e "${YELLOW}Inactive${NC}"
            echo -e "\n${YELLOW}UFW is installed but not active${NC}"
            echo "Would you like to activate it now? (recommended)"
            read -p "Activate UFW? (y/n): " activate
            if [[ $activate =~ ^[Yy] ]]; then
                echo "Activating UFW..."
                sudo ufw --force enable
                echo -e "${GREEN}✓ UFW activated${NC}"
            else
                echo -e "${YELLOW}Warning: Continuing with inactive firewall${NC}"
            fi
        else
            echo -e "${GREEN}Active${NC}"
        fi
    else
        if ! sudo iptables -L >/dev/null 2>&1; then
            echo -e "${RED}Error${NC}"
            echo -e "\n${RED}Cannot access iptables. Are you running with sudo?${NC}"
            exit 1
        fi
        echo -e "${GREEN}Active${NC}"
    fi
    
    # Check for critical rules
    echo -n "Checking for SSH access rules... "
    local has_ssh=false
    if [ "$firewall_type" = "ufw" ]; then
        if sudo ufw status | grep -q "22/tcp"; then
            has_ssh=true
        fi
    else
        if sudo iptables -L INPUT -n | grep -q "dpt:22"; then
            has_ssh=true
        fi
    fi
    
    if [ "$has_ssh" = true ]; then
        echo -e "${GREEN}Found${NC}"
    else
        echo -e "${YELLOW}Not found${NC}"
        echo -e "\n${YELLOW}Warning: No SSH access rules detected${NC}"
        echo "If you're accessing this system remotely, you may want to add SSH rules"
        echo "before making any changes."
    fi
    
    echo -e "\n${GREEN}✓ Using $firewall_type${NC}"
    
    # Brief pause to let user read the information
    sleep 1
    return 0
}

# Function to check existing rules
check_existing_rules() {
    echo -e "\n${YELLOW}☕ Checking existing firewall rules...${NC}"
    
    local firewall_type=$(check_firewall)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local existing_rules_file="$BACKUP_DIR/existing_rules_$timestamp.txt"

    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR"

    # Save current rules
    if [ "$firewall_type" = "ufw" ]; then
        if ! sudo ufw status numbered > "$existing_rules_file" 2>/dev/null; then
            echo -e "${RED}Error: Could not get current firewall rules${NC}"
            exit 3
        fi
    else
        if ! sudo iptables -L -n --line-numbers > "$existing_rules_file" 2>/dev/null; then
            echo -e "${RED}Error: Could not get current firewall rules${NC}"
            exit 3
        fi
    fi

    echo -e "${GREEN}✓ Current rules saved to: $existing_rules_file${NC}"
    
    # Handle automation mode
    case "$AUTOMATION_TYPE" in
        skip)
            echo "[TEST MODE] Skipping rule review"
            return 0
            ;;
        input|none|*)
            echo -e "Would you like to review existing rules before proceeding?"
            read -p "Review rules? (y/n): " review
            ;;
    esac

    if [[ $review =~ ^[Yy] ]]; then
        echo -e "\n${YELLOW}How would you like to review the rules?${NC}"
        echo "1) Simple view with basic options"
        echo "2) Detailed analysis with recommendations"
        read -p "Enter your choice (1-2): " review_choice
        
        case $review_choice in
            1) show_rules_with_menu "$existing_rules_file" ;;
            2) analyze_rules "$existing_rules_file" ;;
            *) 
                echo -e "${RED}Invalid choice. Using simple view.${NC}"
                show_rules_with_menu "$existing_rules_file"
                ;;
        esac
    fi

    # If we get here, user either skipped review or finished reviewing
    return 0
}

# Function to show rules with menu options
show_rules_with_menu() {
    local rules_file="$1"
    
    # Display rules
    echo -e "\n${YELLOW}Current Firewall Rules:${NC}"
    cat "$rules_file"
    
    # Show options menu
    echo -e "\n${YELLOW}What would you like to do?${NC}"
    echo "1) Continue with adding new rules"
    echo "2) Return to main menu"
    echo "3) Exit application"
    echo
    read -p "Enter your choice (1-3): " choice
    
    case $choice in
        1) return 0 ;;
        2) show_menu ;;
        3) 
            echo -e "${YELLOW}Thanks for using IPCoffee! Stay caffeinated! ☕${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            show_rules_with_menu "$rules_file"
            ;;
    esac
}

# Function to analyze and categorize rules
analyze_rules() {
    local rules_file="$1"
    local temp_dir=$(mktemp -d)
    local current_rules="$temp_dir/current_rules.txt"
    local add_rules="$temp_dir/add_rules.txt"
    
    # Get current firewall rules (without header lines)
    if ! sudo ufw status numbered | grep -E "^\[[0-9]+\]" > "$current_rules" 2>/dev/null; then
        echo -e "${YELLOW}No existing firewall rules found${NC}"
        > "$current_rules"  # Create empty file
    fi
    
    # Check if add_rules.txt exists and has content
    if [ ! -f "add_rules.txt" ]; then
        echo -e "${RED}Error: add_rules.txt not found${NC}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Get rules from add_rules.txt (skip comments and empty lines)
    if ! grep -v "^#" add_rules.txt | grep -v "^$" > "$add_rules" 2>/dev/null; then
        echo -e "${YELLOW}No rules found in add_rules.txt${NC}"
        > "$add_rules"  # Create empty file
    fi

    echo -e "\n${YELLOW}Analyzing firewall rules...${NC}\n"

    # Section 1: Rules that exist in both files
    echo "Rules in your add_rules.txt file that are already active in the firewall:"
    echo "Status: active"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        read -r ip port comment <<< "$line"
        if grep -q "$ip.*$port" "$current_rules" 2>/dev/null; then
            grep "$ip.*$port" "$current_rules"
        fi
    done < "add_rules.txt"

    echo -e "\n==================================================================================\n"

    # Section 2: Rules in add_rules.txt not in current rules
    echo "Rules in add_rules.txt that will be added:"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        read -r ip port comment <<< "$line"
        if ! grep -q "$ip.*$port" "$current_rules" 2>/dev/null; then
            printf "[ *] %-25s ALLOW IN    %-20s (NEW)\n" "$port" "$ip"
        fi
    done < "add_rules.txt"

    echo -e "\n==================================================================================\n"

    # Section 3: Current rules not in add_rules.txt
    echo "Current firewall rules not in your add_rules.txt file:"
    echo "Status: active"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    while IFS= read -r line; do
        rule_found=false
        ip=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" 2>/dev/null || echo "")
        port=$(echo "$line" | awk '{print $2}' 2>/dev/null || echo "")
        
        if [ -n "$ip" ] && [ -n "$port" ]; then
            while IFS= read -r add_rule; do
                [[ "$add_rule" =~ ^#.*$ || -z "$add_rule" ]] && continue
                read -r add_ip add_port add_comment <<< "$add_rule"
                if [[ "$ip" == "$add_ip" && "$port" == "$add_port" ]]; then
                    rule_found=true
                    break
                fi
            done < "add_rules.txt"
            
            if ! $rule_found; then
                if [[ "$port" == "22/tcp" ]]; then
                    echo "$line     ** CRITICAL: SSH Access Rule **"
                else
                    echo "$line"
                fi
            fi
        fi
    done < "$current_rules"

    # Cleanup
    rm -rf "$temp_dir"

    echo -e "\n\nHow would you like to proceed?"
    echo "1) Continue with adding new rules"
    echo "2) Return to main menu"
    echo "3) Exit application"
    
    read -p "Enter your choice (1-3): " choice
    case $choice in
        1) return 0 ;;
        2) show_menu ;;
        3) 
            echo -e "${YELLOW}Thanks for using IPCoffee! Stay caffeinated! ☕${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            analyze_rules "$rules_file"
            ;;
    esac
}

# Function to generate detailed rule report
generate_detailed_report() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="$BACKUP_DIR/rule_report_$timestamp.txt"
    
    echo -e "\n${YELLOW}Generating detailed rule report...${NC}"
    
    # Create report header
    cat > "$report_file" << EOF
IPCoffee Firewall Rule Analysis Report
Generated: $(date)
==============================================

SUMMARY OF RECOMMENDED ACTIONS:

EOF

    # Analyze current rules
    echo "1. CRITICAL SYSTEM RULES" >> "$report_file"
    echo "------------------------" >> "$report_file"
    while IFS= read -r line; do
        if [[ "$line" =~ "22/tcp" ]] || [[ "$line" =~ "SSH" ]]; then
            echo "✓ SSH Access (Port 22) - MAINTAIN THIS RULE" >> "$report_file"
        fi
    done < <(sudo ufw status numbered)
    echo >> "$report_file"

    # Analyze add_rules.txt rules
    echo "2. RULES IN add_rules.txt" >> "$report_file"
    echo "------------------------" >> "$report_file"
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        read -r ip port comment <<< "$line"
        if sudo ufw status numbered | grep -q "$ip.*$port"; then
            echo "! DUPLICATE: $ip ($port) - $comment" >> "$report_file"
            echo "  Recommendation: Remove from add_rules.txt" >> "$report_file"
        else
            echo "+ NEW RULE: $ip ($port) - $comment" >> "$report_file"
            echo "  Recommendation: Will be added" >> "$report_file"
        fi
    done < "add_rules.txt"
    echo >> "$report_file"

    # Analyze existing rules not in add_rules.txt
    echo "3. EXISTING RULES NOT IN add_rules.txt" >> "$report_file"
    echo "------------------------------------" >> "$report_file"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[.*\] ]]; then
            local rule_found=false
            while IFS= read -r add_rule; do
                [[ "$add_rule" =~ ^#.*$ || -z "$add_rule" ]] && continue
                if [[ "$line" =~ $(echo "$add_rule" | awk '{print $1}') ]]; then
                    rule_found=true
                    break
                fi
            done < "add_rules.txt"
            
            if ! $rule_found; then
                echo "? UNMANAGED: $line" >> "$report_file"
                if [[ "$line" =~ "22/tcp" ]]; then
                    echo "  Recommendation: KEEP (System Critical)" >> "$report_file"
                else
                    echo "  Recommendation: Review for necessity" >> "$report_file"
                fi
            fi
        fi
    done < <(sudo ufw status numbered)

    # Add recommendations section
    cat >> "$report_file" << EOF

RECOMMENDED ACTIONS:
==================
1. Review all rules marked with '?' for necessity
2. Remove duplicate rules from add_rules.txt
3. Verify all new rules before adding
4. Maintain critical system rules (SSH, etc.)

SAFETY NOTES:
============
- Always maintain SSH access rules
- Test changes on non-production systems first
- Keep backups of working configurations
- Document all changes made

EOF

    echo -e "${GREEN}✓ Report generated: $report_file${NC}"
    
    # Offer to view the report
    echo -e "\nWould you like to:"
    echo "1) View the report now"
    echo "2) Continue without viewing"
    echo "3) Exit"
    
    read -p "Enter your choice (1-3): " view_choice
    case $view_choice in
        1)
            less "$report_file"
            ;;
        2)
            return 0
            ;;
        3)
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            ;;
    esac
}

# Function to handle adding rules
handle_add_rules() {
    echo -e "\n${YELLOW}☕ Preparing to add new firewall rules...${NC}"
    
    # Check for rules file
    if [ ! -f "add_rules.txt" ]; then
        echo -e "${RED}Oops! Can't find add_rules.txt${NC}"
        echo "I'll create a sample file for you..."
        
        cat > add_rules.txt << 'EOF'
# IPCoffee Rules File
# Format: IP_ADDRESS PORT/PROTOCOL COMMENT
# Example:
192.168.1.100   80/tcp    Web Server
10.0.0.50       22/tcp    SSH Access
172.16.0.10     443/tcp   HTTPS Server

# Lines starting with # are ignored
# Save this file and run the script again!
EOF
        echo -e "${GREEN}✓ Created add_rules.txt with examples${NC}"
        echo "Please edit this file and run the script again!"
        exit 0  # Changed from return 0 to exit 0 for clarity
    fi

    # Verify add_rules.txt has content
    if ! grep -v '^#' add_rules.txt | grep -v '^[[:space:]]*$' > /dev/null; then
        echo -e "${RED}Error: add_rules.txt contains no valid rules${NC}"
        echo "Please add some rules and try again!"
        exit 0
    }

    check_existing_rules

    # Process rules
    local firewall_type=$(check_firewall)
    echo -e "\n${YELLOW}Adding new rules...${NC}"
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        # Parse rule components
        read -r ip port comment <<< "$line"
        
        # Validate IP address
        if ! [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}Invalid IP address: $ip${NC}"
            continue
        fi
        
        # Add the rule based on firewall type
        echo -n "Adding rule for $ip ($comment)... "
        if [ "$firewall_type" = "ufw" ]; then
            if sudo ufw allow from "$ip" to any port "${port%/*}" proto "${port#*/}" >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}Failed${NC}"
            fi
        else
            if sudo iptables -A INPUT -p "${port#*/}" -s "$ip" --dport "${port%/*}" -j ACCEPT >/dev/null 2>&1; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}Failed${NC}"
            fi
        fi
    done < add_rules.txt
    
    echo -e "\n${GREEN}✓ Firewall rules have been updated!${NC}"
    
    # Show final menu
    echo -e "\nWhat would you like to do next?"
    echo "1) Return to main menu"
    echo "2) Exit application"
    
    read -p "Enter your choice (1-2): " choice
    case $choice in
        1) show_menu ;;
        2) 
            echo -e "${YELLOW}Thanks for using IPCoffee! Stay caffeinated! ☕${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice. Returning to main menu...${NC}"
            show_menu
            ;;
    esac
}

# Function to handle rule deletion options
handle_delete_rules() {
    echo -e "\n${YELLOW}☕ Preparing to delete firewall rules...${NC}"
    local firewall_type=$(check_firewall)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$BACKUP_DIR/pre_delete_backup_$timestamp.txt"

    # Parse deletion options
    case "${2:-}" in
        --all)
            confirm_and_delete_all "$firewall_type" "$backup_file"
            ;;
        --number)
            if [[ -n "${3:-}" && "${3:-}" =~ ^[0-9]+$ ]]; then
                confirm_and_delete_single "$firewall_type" "$backup_file" "$3"
            else
                echo -e "${RED}Error: Invalid rule number${NC}"
                echo "Usage: $0 -d --number <rule_number>"
                exit 1
            fi
            ;;
        --range)
            if [[ -n "${3:-}" && "${3:-}" =~ ^[0-9]+-[0-9]+$ ]]; then
                local start_num="${3%-*}"
                local end_num="${3#*-}"
                confirm_and_delete_range "$firewall_type" "$backup_file" "$start_num" "$end_num"
            else
                echo -e "${RED}Error: Invalid range format${NC}"
                echo "Usage: $0 -d --range <start>-<end>"
                exit 1
            fi
            ;;
        "")
            # Interactive mode
            show_delete_menu "$firewall_type" "$backup_file"
            ;;
        *)
            echo -e "${RED}Error: Invalid delete option${NC}"
            echo "Usage: $0 -d [--all|--number <n>|--range <start-end>]"
            exit 1
            ;;
    esac
}

# Function to show interactive deletion menu
show_delete_menu() {
    local firewall_type="$1"
    local backup_file="$2"

    # Handle automation mode
    if [ "$AUTOMATION_TYPE" = "skip" ]; then
        echo "[TEST MODE] Skipping deletion menu interaction"
        return 0
    fi

    while true; do
        echo -e "\n${YELLOW}☕ Rule Deletion Menu${NC}"
        echo "1) Show current rules"
        echo "2) Delete selected rule(s)"
        echo "3) Delete all rules"
        echo "4) Undo last deletion"
        echo "5) Return to main menu"
        echo "6) Exit application"
        
        read -p "Enter your choice (1-6): " choice

        case $choice in
            1)
                show_current_rules "$firewall_type"
                echo -e "\nPress Enter to continue..."
                read -r
                ;;
            2)
                delete_rules_interactive "$firewall_type" "$backup_file"
                ;;
            3)
                confirm_and_delete_all "$firewall_type" "$backup_file"
                ;;
            4)
                undo_last_deletion "$firewall_type"
                ;;
            5)
                return 0
                ;;
            6)
                echo -e "${YELLOW}Thanks for using IPCoffee! Stay caffeinated! ☕${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice. Please try again.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Function to show current rules
show_current_rules() {
    local firewall_type="$1"
    echo -e "\n${YELLOW}Current Firewall Rules:${NC}"
    
    if [ "$firewall_type" = "ufw" ]; then
        if ! sudo ufw status numbered > /dev/null 2>&1; then
            echo -e "${RED}Error: Could not get UFW rules${NC}"
            return 1
        fi
        
        # Get UFW status
        local status=$(sudo ufw status | grep "Status:" | awk '{print $2}')
        echo -e "Firewall Status: ${GREEN}$status${NC}\n"
        
        # Show rules
        if sudo ufw status numbered | grep -q "\["; then
            sudo ufw status numbered
        else
            echo -e "${YELLOW}No rules currently configured${NC}"
        fi
    else
        if ! sudo iptables -L -n --line-numbers > /dev/null 2>&1; then
            echo -e "${RED}Error: Could not get iptables rules${NC}"
            return 1
        fi
        
        # Show rules
        if sudo iptables -L -n --line-numbers | grep -v "^Chain" | grep -v "^num" | grep -q "[0-9]"; then
            sudo iptables -L -n --line-numbers
        else
            echo -e "${YELLOW}No rules currently configured${NC}"
        fi
    fi
    
    return 0
}

# Function to delete selected rule(s) interactively
delete_rules_interactive() {
    local firewall_type="$1"
    local backup_file="$2"
    local max_rules=0

    # Show current rules and get max rule number
    echo -e "\n${YELLOW}Current rules:${NC}"
    if [ "$firewall_type" = "ufw" ]; then
        show_current_rules "$firewall_type"
        max_rules=$(sudo ufw status numbered | grep -c "^\[")
    else
        show_current_rules "$firewall_type"
        max_rules=$(sudo iptables -L INPUT --line-numbers | grep -c "^[0-9]")
    fi

    # Check if there are any rules to delete
    if [ "$max_rules" -eq 0 ]; then
        echo -e "\n${YELLOW}No rules available to delete${NC}"
        echo -e "Press Enter to continue..."
        read -r
        return 0
    fi

    while true; do
        echo -e "\n${YELLOW}Enter rule number(s) to delete:${NC}"
        echo "Options:"
        echo "  - Single rule:  5"
        echo "  - Range:        5-8"
        echo "  - Multiple:     5,8,11"
        echo "  - Mixed:        5-8,11,14-16"
        echo "  - Enter 0 to cancel"
        echo
        read -p "> " selection

        # Check for cancel
        if [ "$selection" = "0" ]; then
            echo -e "${YELLOW}Operation cancelled${NC}"
            return 0
        fi

        # Validate input format
        if ! [[ "$selection" =~ ^[0-9,\-]+$ ]]; then
            echo -e "${RED}Invalid format. Use numbers, commas, and hyphens only${NC}"
            continue
        fi

        # Parse and validate all numbers in the selection
        local invalid=false
        local rules_to_delete=()
        
        # Process each comma-separated part
        IFS=',' read -ra PARTS <<< "$selection"
        for part in "${PARTS[@]}"; do
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                # Range of rules
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"
                
                if [ "$start" -gt "$end" ]; then
                    echo -e "${RED}Invalid range: $start-$end (start should be less than end)${NC}"
                    invalid=true
                    break
                fi
                
                if [ "$start" -lt 1 ] || [ "$end" -gt "$max_rules" ]; then
                    echo -e "${RED}Rule numbers must be between 1 and $max_rules${NC}"
                    invalid=true
                    break
                fi
                
                for ((i=start; i<=end; i++)); do
                    rules_to_delete+=("$i")
                done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                # Single rule
                if [ "$part" -lt 1 ] || [ "$part" -gt "$max_rules" ]; then
                    echo -e "${RED}Rule numbers must be between 1 and $max_rules${NC}"
                    invalid=true
                    break
                fi
                rules_to_delete+=("$part")
            else
                echo -e "${RED}Invalid format in: $part${NC}"
                invalid=true
                break
            fi
        done

        [ "$invalid" = true ] && continue

        # Remove duplicates and sort
        rules_to_delete=($(printf "%d\n" "${rules_to_delete[@]}" | sort -rn | uniq))

        # Show rules to be deleted
        echo -e "\n${YELLOW}Rules to be deleted:${NC}"
        for rule in "${rules_to_delete[@]}"; do
            if [ "$firewall_type" = "ufw" ]; then
                sudo ufw status numbered | grep "^\[$rule\]"
            else
                sudo iptables -L INPUT --line-numbers | grep "^$rule "
            fi
        done

        # Confirm deletion
        echo -e "\n${RED}Warning: This action cannot be undone without using the backup restore feature.${NC}"
        read -p "Are you sure you want to delete these rules? (y/n): " confirm
        
        if [[ $confirm =~ ^[Yy] ]]; then
            # Create backup before deletion
            create_backup "$firewall_type" "$backup_file"
            
            # Delete rules (in reverse order to maintain rule numbers)
            local success=true
            for rule in "${rules_to_delete[@]}"; do
                echo -n "Deleting rule $rule... "
                if [ "$firewall_type" = "ufw" ]; then
                    if sudo ufw delete "$rule"; then
                        echo -e "${GREEN}✓${NC}"
                    else
                        echo -e "${RED}Failed${NC}"
                        success=false
                    fi
                else
                    if sudo iptables -D INPUT "$rule"; then
                        echo -e "${GREEN}✓${NC}"
                    else
                        echo -e "${RED}Failed${NC}"
                        success=false
                    fi
                fi
            done

            if [ "$success" = true ]; then
                echo -e "\n${GREEN}✓ All selected rules deleted successfully${NC}"
            else
                echo -e "\n${YELLOW}Warning: Some rules may not have been deleted${NC}"
            fi
            break
        else
            echo -e "${YELLOW}Deletion cancelled${NC}"
            break
        fi
    done

    echo -e "\nPress Enter to continue..."
    read -r
    return 0
}

# Function to confirm and delete all rules
confirm_and_delete_all() {
    local firewall_type="$1"
    local backup_file="$2"

    # Check if there are any rules to delete
    local has_rules=false
    if [ "$firewall_type" = "ufw" ]; then
        if sudo ufw status numbered | grep -q "^\["; then
            has_rules=true
        fi
    else
        if sudo iptables -L INPUT --line-numbers | grep -q "^[0-9]"; then
            has_rules=true
        fi
    fi

    if [ "$has_rules" = false ]; then
        echo -e "\n${YELLOW}No rules currently configured to delete${NC}"
        echo -e "Press Enter to continue..."
        read -r
        return 0
    fi

    # Show current rules
    echo -e "\n${YELLOW}Current rules that will be deleted:${NC}"
    show_current_rules "$firewall_type"

    # Create backup before deletion
    create_backup "$firewall_type" "$backup_file"

    # Handle automation mode for confirmation
    if [ "$AUTOMATION_TYPE" = "skip" ]; then
        echo "[TEST MODE] Skipping delete all confirmation"
        return 0
    fi

    # Confirm deletion with extra warning
    echo -e "\n${RED}WARNING: This will delete ALL firewall rules!${NC}"
    echo -e "${RED}This includes any SSH access rules that may be critical for remote management.${NC}"
    echo -e "A backup will be saved to: $backup_file"
    echo
    read -p "Type 'DELETE ALL' to confirm (or anything else to cancel): " confirm
    
    if [ "$confirm" = "DELETE ALL" ]; then
        echo -e "\n${YELLOW}Deleting all rules...${NC}"
        
        if [ "$firewall_type" = "ufw" ]; then
            if sudo ufw reset; then
                echo -e "${GREEN}✓ All rules deleted successfully${NC}"
            else
                echo -e "${RED}Failed to delete rules${NC}"
                return 1
            fi
        else
            if sudo iptables -F; then
                echo -e "${GREEN}✓ All rules deleted successfully${NC}"
            else
                echo -e "${RED}Failed to delete rules${NC}"
                return 1
            fi
        fi
        
        echo -e "\n${YELLOW}Note: You may want to add back any critical access rules${NC}"
    else
        echo -e "${YELLOW}Deletion cancelled${NC}"
    fi

    echo -e "\nPress Enter to continue..."
    read -r
    return 0
}

# Function to create backup
create_backup() {
    local firewall_type="$1"
    local backup_file="$2"
    local backup_type="${3:-manual}"  # Can be 'manual' or 'auto'

    echo -e "${YELLOW}Creating backup...${NC}"
    
    # Ensure backup directory exists
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        echo -e "${RED}Error: Could not create backup directory${NC}"
        return 1
    }

    # Create the backup
    if [ "$firewall_type" = "ufw" ]; then
        if ! sudo ufw status numbered > "$backup_file" 2>/dev/null; then
            echo -e "${RED}Error: Could not create UFW backup${NC}"
            return 1
        fi
        
        # Add metadata to backup
        local temp_file=$(mktemp)
        {
            echo "# IPCoffee Firewall Backup"
            echo "# Date: $(date)"
            echo "# Type: $backup_type"
            echo "# Firewall: UFW"
            echo "#"
            cat "$backup_file"
        } > "$temp_file"
        mv "$temp_file" "$backup_file"
        
    else
        if ! sudo iptables-save > "$backup_file" 2>/dev/null; then
            echo -e "${RED}Error: Could not create iptables backup${NC}"
            return 1
        fi
        
        # Add metadata to backup
        local temp_file=$(mktemp)
        {
            echo "# IPCoffee Firewall Backup"
            echo "# Date: $(date)"
            echo "# Type: $backup_type"
            echo "# Firewall: iptables"
            echo "#"
            cat "$backup_file"
        } > "$temp_file"
        mv "$temp_file" "$backup_file"
    fi

    # Verify backup was created and has content
    if [ ! -s "$backup_file" ]; then
        echo -e "${RED}Error: Backup file is empty${NC}"
        return 1
    fi

    # Set secure permissions
    chmod 600 "$backup_file" 2>/dev/null || {
        echo -e "${RED}Warning: Could not set secure permissions on backup file${NC}"
    }

    if [ "$backup_type" = "manual" ]; then
        echo -e "${GREEN}✓ Backup created: $backup_file${NC}"
        
        # Clean up old backups (keep last 10)
        local backup_count=$(ls -1 "$BACKUP_DIR"/pre_delete_backup_* 2>/dev/null | wc -l)
        if [ "$backup_count" -gt 10 ]; then
            echo -e "${YELLOW}Cleaning up old backups...${NC}"
            ls -1t "$BACKUP_DIR"/pre_delete_backup_* | tail -n +11 | xargs rm -f
            echo -e "${GREEN}✓ Old backups cleaned up${NC}"
        fi
    fi

    return 0
}

# Function to undo last deletion
undo_last_deletion() {
    local firewall_type="$1"
    local latest_backup=$(ls -t "$BACKUP_DIR"/pre_delete_backup_* 2>/dev/null | head -n1)

    if [ -z "$latest_backup" ]; then
        echo -e "\n${RED}No backup found to restore${NC}"
        echo -e "Press Enter to continue..."
        read -r
        return 1
    fi

    # Show current rules and backup rules
    echo -e "\n${YELLOW}Current rules:${NC}"
    show_current_rules "$firewall_type"
    
    echo -e "\n${YELLOW}Rules from backup that will be restored:${NC}"
    if [ "$firewall_type" = "ufw" ]; then
        cat "$latest_backup"
    else
        grep '^-A INPUT' "$latest_backup" | nl
    fi

    # Handle automation mode
    if [ "$AUTOMATION_TYPE" = "skip" ]; then
        echo "[TEST MODE] Skipping restore confirmation"
        return 0
    fi

    echo -e "\n${RED}Warning: This will replace all current rules with the backup rules!${NC}"
    echo -e "Backup file: $latest_backup"
    echo
    read -p "Are you sure you want to restore these rules? (y/n): " confirm
    
    if [[ $confirm =~ ^[Yy] ]]; then
        echo -e "\n${YELLOW}Restoring rules from backup...${NC}"
        
        if [ "$firewall_type" = "ufw" ]; then
            # Create a temporary script for UFW restoration
            local temp_script=$(mktemp)
            echo "#!/bin/bash" > "$temp_script"
            echo "sudo ufw --force reset" >> "$temp_script"
            
            # Extract and add each rule from the backup
            while read -r rule; do
                if [[ "$rule" =~ ^\[.*\] ]]; then
                    # Remove the rule number and brackets
                    rule=${rule#*] }
                    echo "sudo ufw $rule" >> "$temp_script"
                fi
            done < "$latest_backup"
            
            # Execute the restoration script
            if bash "$temp_script"; then
                echo -e "${GREEN}✓ Rules restored successfully${NC}"
                rm -f "$temp_script"
            else
                echo -e "${RED}Failed to restore rules${NC}"
                rm -f "$temp_script"
                return 1
            fi
        else
            if sudo iptables-restore < "$latest_backup"; then
                echo -e "${GREEN}✓ Rules restored successfully${NC}"
            else
                echo -e "${RED}Failed to restore rules${NC}"
                return 1
            fi
        fi
    else
        echo -e "${YELLOW}Restore cancelled${NC}"
    fi

    echo -e "\nPress Enter to continue..."
    read -r
    return 0
}

# Show a friendly menu
show_menu() {
    while true; do
        echo -e "\n${YELLOW}☕ Welcome to IPCoffee! ☕${NC}"
        echo "What would you like to brew today?"
        echo
        echo "1) Add new firewall rules"
        echo "2) Delete existing rules"
        echo "3) Show current rules"
        echo "4) Exit application"
        echo

        case "$AUTOMATION_TYPE" in
            skip)
                echo "[TEST MODE] Skipping menu interaction"
                return 0
                ;;
            input|none|*)
                read -p "Enter your choice (1-4): " choice
                ;;
        esac

        case $choice in
            1) 
                handle_add_rules
                ;;
            2) 
                handle_delete_rules
                ;;
            3)
                local firewall_type=$(check_firewall)
                show_current_rules "$firewall_type"
                echo -e "\nPress Enter to continue..."
                read -r
                ;;
            4) 
                echo -e "\n${GREEN}Thanks for using IPCoffee! Stay caffeinated! ☕${NC}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}Invalid choice. Please try again.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Function to check script version
check_version() {
    local current_version="1.0.0"
    local version_url="https://raw.githubusercontent.com/OutOfOrbit/ipcoffee/main/VERSION"
    
    echo -e "\n${YELLOW}Checking IPCoffee version...${NC}"
    echo "Current version: $current_version"
    
    # Only check online version if we have curl or wget
    if command -v curl >/dev/null 2>&1; then
        local latest_version
        latest_version=$(curl -sf "$version_url" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$latest_version" ]; then
            if [ "$latest_version" != "$current_version" ]; then
                echo -e "${YELLOW}New version available: $latest_version${NC}"
                echo "Visit: https://github.com/OutOfOrbit/ipcoffee"
            else
                echo -e "${GREEN}You have the latest version${NC}"
            fi
        fi
    elif command -v wget >/dev/null 2>&1; then
        local latest_version
        latest_version=$(wget -qO- "$version_url" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$latest_version" ]; then
            if [ "$latest_version" != "$current_version" ]; then
                echo -e "${YELLOW}New version available: $latest_version${NC}"
                echo "Visit: https://github.com/OutOfOrbit/ipcoffee"
            else
                echo -e "${GREEN}You have the latest version${NC}"
            fi
        fi
    fi
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    
    # Remove any temporary files
    rm -f /tmp/ipcoffee_*
    
    # Reset text formatting
    echo -en "${NC}"
    
    exit $exit_code
}

# Set up trap for cleanup
trap cleanup EXIT

# Main script execution
main() {
    # Check if we're running as root
    if [[ $EUID -ne 0 ]]; then 
        echo -e "${RED}☕ Oops! Please run with sudo${NC}"
        echo "Example: sudo ./ipcoffee.sh"
        exit 1
    fi

    # Create backup directory if it doesn't exist
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        echo -e "${RED}Error: Could not create backup directory${NC}"
        exit 1
    fi

    # Check version (non-blocking)
    check_version &
    local version_check_pid=$!

    # Verify firewall setup
    verify_firewall_setup

    # Wait for version check to complete (max 2 seconds)
    { sleep 2; kill -0 $version_check_pid 2>/dev/null && kill $version_check_pid; } &
    wait $version_check_pid 2>/dev/null || true

    # Handle command line arguments
    case "${1:-}" in
        -a|--add)
            handle_add_rules
            ;;
        -d|--delete)
            handle_delete_rules "$@"
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "IPCoffee version 1.0.0"
            exit 0
            ;;
        *)
            show_menu
            ;;
    esac
}

# Show help information
show_help() {
    cat << EOF
IPCoffee - Firewall Rule Manager
Version: 1.0.0

Usage:
  ./ipcoffee.sh [options]

Options:
  -a, --add              Add new firewall rules from add_rules.txt
  -d, --delete           Delete firewall rules (interactive)
      --all             Delete all rules
      --number <n>      Delete rule number n
      --range <x-y>     Delete rules from x to y
  -h, --help            Show this help message
  -v, --version         Show version information

Examples:
  ./ipcoffee.sh                     # Start interactive mode
  ./ipcoffee.sh -a                  # Add rules from add_rules.txt
  ./ipcoffee.sh -d --number 5       # Delete rule number 5
  ./ipcoffee.sh -d --range 5-8      # Delete rules 5 through 8

For more information, visit:
https://github.com/OutOfOrbit/ipcoffee
EOF
}

# Start the script
main "$@"

