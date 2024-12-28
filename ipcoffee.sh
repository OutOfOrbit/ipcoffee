#!/bin/bash
#
# IPCoffee - Firewall Rule Manager
# Version: 2.0.0
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

    # Normal mode checks for active firewalls
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        echo "ufw"
    elif command -v iptables >/dev/null 2>&1 && iptables -L >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

# Verify firewall is properly set up
verify_firewall_setup() {
    echo "Checking firewall setup..."
    local firewall_type=$(check_firewall)
    echo "Detected firewall type: $firewall_type"
    
    if [ "$firewall_type" = "none" ]; then
        echo -e "${RED}☹️ No supported firewall found!${NC}"
        echo "Please install either ufw or iptables first."
        echo "For Ubuntu/Debian: sudo apt install ufw"
        exit 2
    fi
    
    echo -e "${GREEN}✓ Using $firewall_type${NC}"
}

# Function to check existing rules
check_existing_rules() {
    echo -e "\n${YELLOW}☕ Checking existing firewall rules...${NC}"
    
    local firewall_type=$(check_firewall)
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local existing_rules_file="$BACKUP_DIR/existing_rules_$timestamp.txt"

    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR"

    if [ "$firewall_type" = "ufw" ]; then
        sudo ufw status numbered > "$existing_rules_file"
    else
        sudo iptables -L -n --line-numbers > "$existing_rules_file"
    fi

    echo -e "${GREEN}✓ Current rules saved to: $existing_rules_file${NC}"
    
    case "$AUTOMATION_TYPE" in
        skip)
            echo "[TEST MODE] Skipping rule review"
            return 0
            ;;
        input)
            echo -e "Would you like to review existing rules before proceeding?"
            read -p "Review rules? (y/n): " review
            ;;
        none|*)
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
    echo "2) View rules again"
    echo "3) Cancel operation"
    echo
    read -p "Enter your choice (1-3): " choice
    
    case $choice in
        1) return 0 ;;
        2) show_rules_with_menu "$rules_file" ;;
        3) 
            echo -e "${YELLOW}Operation cancelled${NC}"
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
    local active_matches="$temp_dir/active_matches.txt"
    local inactive_matches="$temp_dir/inactive_matches.txt"
    local other_active="$temp_dir/other_active.txt"
    local other_inactive="$temp_dir/other_inactive.txt"
    local critical_rules="$temp_dir/critical.txt"

    # Get current firewall rules
    sudo ufw status numbered > "$temp_dir/current_rules.txt"

    # Create critical rules list (customize this list as needed)
    cat > "$critical_rules" << EOF
22/tcp:SSH Access (Required for remote management)
EOF

    echo -e "\n${YELLOW}Analyzing firewall rules...${NC}\n"

    # Section 1: Matching Active Rules
    echo "Rules in your add_rules.txt file that are already active in the firewall:"
    echo "Status: active"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        read -r ip port comment <<< "$line"
        if grep -q "$ip.*$port" "$temp_dir/current_rules.txt"; then
            grep "$ip.*$port" "$temp_dir/current_rules.txt" | sed 's/$/ Will be ignored/'
        fi
    done < "$rules_file"

    echo -e "\n==================================================================================\n"

    # Section 2: Matching Inactive Rules
    echo "Rules in your add_rules.txt file that currently exist in the firewall but that are inactive:"
    echo "Status: inactive"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    # ... (implementation for inactive rules)

    echo -e "\n==================================================================================\n"

    # Section 3: Other Existing Rules
    echo "The following rules currently exist in the firewall are not in your add_rules.txt file."
    echo "Status: active"
    echo
    echo "     To                         Action      From"
    echo "     --                         ------      ----"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[.*\] ]]; then
            local rule_port=$(echo "$line" | awk '{print $2}')
            if grep -q "^$rule_port:" "$critical_rules"; then
                local critical_msg=$(grep "^$rule_port:" "$critical_rules" | cut -d: -f2-)
                echo "$line IMPORTANT NOTE: $critical_msg"
            else
                echo "$line"
            fi
        fi
    done < "$temp_dir/current_rules.txt"

    echo -e "\n\nStatus: inactive"
    # ... (implementation for other inactive rules)

    echo -e "\n\nHow would you like to proceed?"
    echo "1)  Deactivate all         *** Not recommended since some rules are generally necessary"
    echo "2)  Delete all            *** Not recommended since some rules are generally necessary"
    echo "3)  Receive an itemized report that can be used to provide detailed instructions"
    echo "4)  Quit"

    # Cleanup temp files
    rm -rf "$temp_dir"

    read -p "Enter your choice (1-4): " choice
    case $choice in
        1) echo "Deactivation functionality to be implemented" ;;
        2) echo "Deletion functionality to be implemented" ;;
        3) generate_detailed_report ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid choice${NC}" ;;
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
        return 0
    fi

    check_existing_rules

    # Process rules
    local firewall_type=$(check_firewall)
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
        if [ "$firewall_type" = "ufw" ]; then
            sudo ufw allow from "$ip" to any port "${port%/*}" proto "${port#*/}"
        else
            sudo iptables -A INPUT -p "${port#*/}" -s "$ip" --dport "${port%/*}" -j ACCEPT
        fi
        
        echo -e "${GREEN}✓ Added rule for $ip ($comment)${NC}"
    done < add_rules.txt
    
    echo -e "\n${GREEN}✓ Firewall rules have been updated!${NC}"
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
        echo "2) Delete single rule"
        echo "3) Delete range of rules"
        echo "4) Delete all rules"
        echo "5) Undo last deletion"
        echo "6) Return to main menu"
        
        case "$AUTOMATION_TYPE" in
            skip)
                echo "[TEST MODE] Skipping menu choice"
                return 0
                ;;
            input)
                read -p "Enter your choice (1-6): " choice
                ;;
            none|*)
                read -p "Enter your choice (1-6): " choice
                ;;
        esac

        case $choice in
            1)
                show_current_rules "$firewall_type"
                ;;
            2)
                delete_single_rule_interactive "$firewall_type" "$backup_file"
                ;;
            3)
                delete_range_interactive "$firewall_type" "$backup_file"
                ;;
            4)
                confirm_and_delete_all "$firewall_type" "$backup_file"
                ;;
            5)
                undo_last_deletion "$firewall_type"
                ;;
            6)
                return 0
                ;;
            *)
                echo -e "${RED}Invalid choice. Please try again.${NC}"
                ;;
        esac
    done
}

# Function to show current rules
show_current_rules() {
    local firewall_type="$1"
    echo -e "\n${YELLOW}Current Firewall Rules:${NC}"
    
    if [ "$firewall_type" = "ufw" ]; then
        sudo ufw status numbered
    else
        sudo iptables -L -n --line-numbers
    fi
}

# Function to delete single rule interactively
delete_single_rule_interactive() {
    local firewall_type="$1"
    local backup_file="$2"

    show_current_rules "$firewall_type"
    read -p "Enter rule number to delete: " rule_num

    if [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        confirm_and_delete_single "$firewall_type" "$backup_file" "$rule_num"
    else
        echo -e "${RED}Invalid rule number${NC}"
    fi
}

# Function to delete range of rules interactively
delete_range_interactive() {
    local firewall_type="$1"
    local backup_file="$2"

    show_current_rules "$firewall_type"
    read -p "Enter start rule number: " start_num
    read -p "Enter end rule number: " end_num

    if [[ "$start_num" =~ ^[0-9]+$ && "$end_num" =~ ^[0-9]+$ ]]; then
        confirm_and_delete_range "$firewall_type" "$backup_file" "$start_num" "$end_num"
    else
        echo -e "${RED}Invalid rule numbers${NC}"
    fi
}

# Function to confirm and delete a single rule
confirm_and_delete_single() {
    local firewall_type="$1"
    local backup_file="$2"
    local rule_num="$3"

    # Create backup before deletion
    create_backup "$firewall_type" "$backup_file"

    # Show the rule to be deleted
    echo -e "\n${YELLOW}Rule to be deleted:${NC}"
    if [ "$firewall_type" = "ufw" ]; then
        if ! sudo ufw status numbered | grep -q "^\[$rule_num\]"; then
            echo -e "${YELLOW}No rule found with number $rule_num${NC}"
            return 0
        fi
        sudo ufw status numbered | grep "^\[$rule_num\]"
    else
        if ! sudo iptables -L -n --line-numbers | grep -q "^$rule_num "; then
            echo -e "${YELLOW}No rule found with number $rule_num${NC}"
            return 0
        fi
        sudo iptables -L -n --line-numbers | grep "^$rule_num "
    fi

    # Handle automation mode for confirmation
    if [ "$AUTOMATION_TYPE" = "skip" ]; then
        echo "[TEST MODE] Skipping deletion confirmation"
        return 0
    fi

    read -p "Are you sure you want to delete this rule? (y/n): " confirm
    if [[ $confirm =~ ^[Yy] ]]; then
        if [ "$firewall_type" = "ufw" ]; then
            sudo ufw delete "$rule_num"
        else
            sudo iptables -D INPUT "$rule_num"
        fi
        echo -e "${GREEN}✓ Rule deleted successfully${NC}"
    else
        echo -e "${YELLOW}Deletion cancelled${NC}"
    fi
    return 0
}

# Function to confirm and delete a range of rules
confirm_and_delete_range() {
    local firewall_type="$1"
    local backup_file="$2"
    local start_num="$3"
    local end_num="$4"

    # Create backup before deletion
    create_backup "$firewall_type" "$backup_file"

    # Show rules to be deleted
    echo -e "\n${YELLOW}Rules to be deleted:${NC}"
    if [ "$firewall_type" = "ufw" ]; then
        if ! sudo ufw status numbered | grep -q "^\[$start_num\]"; then
            echo -e "${YELLOW}No rules found in range $start_num-$end_num${NC}"
            return 0
        fi
        sudo ufw status numbered | grep -E "^\[$start_num-$end_num\]"
    else
        if ! sudo iptables -L -n --line-numbers | grep -q "^$start_num "; then
            echo -e "${YELLOW}No rules found in range $start_num-$end_num${NC}"
            return 0
        fi
        sudo iptables -L -n --line-numbers | awk -v start="$start_num" -v end="$end_num" \
            '$1 >= start && $1 <= end'
    fi

    # Handle automation mode for confirmation
    if [ "$AUTOMATION_TYPE" = "skip" ]; then
        echo "[TEST MODE] Skipping range deletion confirmation"
        return 0
    fi

    read -p "Are you sure you want to delete these rules? (y/n): " confirm
    if [[ $confirm =~ ^[Yy] ]]; then
        # Delete rules in reverse order to maintain rule numbers
        for ((i=end_num; i>=start_num; i--)); do
            if [ "$firewall_type" = "ufw" ]; then
                sudo ufw delete "$i" 2>/dev/null || true
            else
                sudo iptables -D INPUT "$i" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Rules deleted successfully${NC}"
    else
        echo -e "${YELLOW}Deletion cancelled${NC}"
    fi
    return 0
}

# Function to confirm and delete all rules
confirm_and_delete_all() {
    local firewall_type="$1"
    local backup_file="$2"

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

    # Confirm deletion
    echo -e "${RED}Warning: This will delete ALL firewall rules!${NC}"
    read -p "Are you sure you want to proceed? (y/n): " confirm
    if [[ $confirm =~ ^[Yy] ]]; then
        if [ "$firewall_type" = "ufw" ]; then
            sudo ufw reset
        else
            sudo iptables -F
        fi
        echo -e "${GREEN}✓ All rules deleted successfully${NC}"
    else
        echo -e "${YELLOW}Deletion cancelled${NC}"
    fi
    return 0
}

# Function to create backup
create_backup() {
    local firewall_type="$1"
    local backup_file="$2"

    echo -e "${YELLOW}Creating backup...${NC}"
    mkdir -p "$BACKUP_DIR"
    
    if [ "$firewall_type" = "ufw" ]; then
        sudo ufw status numbered > "$backup_file"
    else
        sudo iptables-save > "$backup_file"
    fi
    
    echo -e "${GREEN}✓ Backup created: $backup_file${NC}"
}

# Function to undo last deletion
undo_last_deletion() {
    local firewall_type="$1"
    local latest_backup=$(ls -t "$BACKUP_DIR"/pre_delete_backup_* 2>/dev/null | head -n1)

    if [ -z "$latest_backup" ]; then
        echo -e "${RED}No backup found to restore${NC}"
        return 1
    fi

    echo -e "${YELLOW}Restoring from backup: $latest_backup${NC}"
    read -p "Are you sure you want to restore? (y/n): " confirm
    
    if [[ $confirm =~ ^[Yy] ]]; then
        if [ "$firewall_type" = "ufw" ]; then
            sudo ufw reset
            while read -r rule; do
                [[ "$rule" =~ ^\[.*\] ]] && sudo ufw add "${rule#*] }"
            done < "$latest_backup"
        else
            sudo iptables-restore < "$latest_backup"
        fi
        echo -e "${GREEN}✓ Rules restored successfully${NC}"
    else
        echo -e "${YELLOW}Restore cancelled${NC}"
    fi
}

# Show a friendly menu
show_menu() {
    echo -e "\n${YELLOW}☕ Welcome to IPCoffee! ☕${NC}"
    echo "What would you like to brew today?"
    echo
    echo "1) Add new firewall rules"
    echo "2) Delete existing rules"
    echo "3) Exit"
    echo

    case "$AUTOMATION_TYPE" in
        skip)
            echo "[TEST MODE] Skipping menu interaction"
            return 0
            ;;
        input)
            read -p "Enter your choice (1-3): " choice
            ;;
        none|*)
            read -p "Enter your choice (1-3): " choice
            ;;
    esac

    case $choice in
        1) handle_add_rules ;;
        2) handle_delete_rules ;;
        3) 
            echo -e "\n${GREEN}Thanks for using IPCoffee! Stay caffeinated! ☕${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            show_menu
            ;;
    esac
}

# Main script execution
verify_firewall_setup

# Handle command line arguments
case "${1:-}" in
    -a|--add)
        handle_add_rules
        ;;
    -d|--delete)
        handle_delete_rules "$@"
        ;;
    *)
        show_menu
        ;;
esac

