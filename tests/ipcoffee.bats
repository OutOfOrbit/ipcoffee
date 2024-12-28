#!/usr/bin/env bats

# Test Suite for IPCoffee
# Covers all major functionality, edge cases, and error conditions

setup() {
    # Create temporary test environment
    export TEMP_DIR=$(mktemp -d)
    export BACKUP_DIR="$TEMP_DIR/backups"
    export ORIGINAL_PATH=$PATH
    mkdir -p "$BACKUP_DIR"
    
    # Set automation mode
    export IPCOFFEE_AUTO="skip"
    
    # Copy script to temp directory
    cp ./ipcoffee.sh "$TEMP_DIR/"
    cd "$TEMP_DIR"

    # Create mock commands directory
    export MOCK_BIN="$TEMP_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    cd ..
    rm -rf "$TEMP_DIR"
}

# Helper Functions
create_mock_command() {
    local cmd="$1"
    local exit_status="$2"
    local output="$3"
    
    cat > "$MOCK_BIN/$cmd" << EOF
#!/bin/bash
if [[ "\$*" == *"status"* ]]; then
    echo "$output"
fi
exit $exit_status
EOF
    chmod +x "$MOCK_BIN/$cmd"
}

setup_ufw_environment() {
    create_mock_command "ufw" 0 "Status: active"
    create_mock_command "systemctl" 0 "active"
}

setup_iptables_environment() {
    create_mock_command "iptables" 0 ""
    create_mock_command "ufw" 1 ""
}

create_test_rules_file() {
    cat > add_rules.txt << EOF
# Test rules
192.168.1.100   80/tcp    Web Server
10.0.0.50       22/tcp    SSH Access
172.16.0.10     443/tcp   HTTPS Server
EOF
}

# Basic Execution Tests
@test "Script requires sudo privileges" {
    run ./ipcoffee.sh
    [ "$status" -eq 1 ]
    [[ "${lines[0]}" =~ "Please run with sudo" ]]
}

@test "Help menu displays all available options" {
    run ./ipcoffee.sh --help
    [ "$status" -eq 0 ]
    [[ "${output}" =~ "IPCoffee - Firewall Rule Manager" ]]
    [[ "${output}" =~ "Usage:" ]]
    [[ "${output}" =~ "-a, --add" ]]
    [[ "${output}" =~ "-d, --delete" ]]
    [[ "${output}" =~ "--all" ]]
    [[ "${output}" =~ "--number" ]]
    [[ "${output}" =~ "--range" ]]
}

@test "Version information is consistent across all references" {
    run ./ipcoffee.sh --version
    version_output="$output"
    
    # Check version in help text
    run ./ipcoffee.sh --help
    help_version=$(echo "$output" | grep "Version:" | head -n1 | awk '{print $2}')
    
    # Check version in script header
    script_version=$(grep "^# Version:" ipcoffee.sh | awk '{print $3}')
    
    [ "$version_output" = "IPCoffee version $script_version" ]
    [ "$help_version" = "$script_version" ]
}

# Firewall Detection Tests
@test "Detects and prefers UFW when both firewalls are available" {
    setup_ufw_environment
    create_mock_command "iptables" 0 ""
    
    run bash -c 'source ./ipcoffee.sh && check_firewall'
    [ "$output" = "ufw" ]
}

@test "Falls back to iptables when UFW is not available" {
    setup_iptables_environment
    
    run bash -c 'source ./ipcoffee.sh && check_firewall'
    [ "$output" = "iptables" ]
}

@test "Detects inactive UFW and offers activation" {
    create_mock_command "ufw" 0 "Status: inactive"
    export IPCOFFEE_AUTO="input"
    
    run bash -c 'source ./ipcoffee.sh && verify_firewall_setup'
    [[ "${output}" =~ "UFW is installed but not active" ]]
}

@test "Handles missing firewall gracefully" {
    # Remove all mock firewall commands
    rm -f "$MOCK_BIN/ufw" "$MOCK_BIN/iptables"
    
    run sudo ./ipcoffee.sh
    [ "$status" -eq 2 ]
    [[ "${output}" =~ "No supported firewall found" ]]
}

# Rule Format Validation Tests
@test "Validates IP address format - valid IPv4" {
    echo "192.168.1.1 80/tcp test" > add_rules.txt
    run bash -c 'source ./ipcoffee.sh && handle_add_rules'
    [[ ! "${output}" =~ "Invalid IP address" ]]
}

@test "Validates IP address format - invalid IPv4" {
    echo "256.256.256.256 80/tcp test" > add_rules.txt
    run bash -c 'source ./ipcoffee.sh && handle_add_rules'
    [[ "${output}" =~ "Invalid IP address" ]]
}

@test "Validates port format - valid port" {
    echo "192.168.1.1 80/tcp test" > add_rules.txt
    run bash -c 'source ./ipcoffee.sh && handle_add_rules'
    [[ ! "${output}" =~ "Invalid port" ]]
}

@test "Validates port format - invalid port" {
    echo "192.168.1.1 65536/tcp test" > add_rules.txt
    run bash -c 'source ./ipcoffee.sh && handle_add_rules'
    [[ "${output}" =~ "Invalid port" ]]
}

@test "Handles malformed rule lines" {
    echo "malformed_line" > add_rules.txt
    run bash -c 'source ./ipcoffee.sh && handle_add_rules'
    [[ "${output}" =~ "Invalid rule format" ]]
}

# Rule Management Tests
@test "Creates sample add_rules.txt with correct format" {
    rm -f add_rules.txt
    run sudo ./ipcoffee.sh -a
    [ -f "add_rules.txt" ]
    [[ "$(cat add_rules.txt)" =~ "IPCoffee Rules File" ]]
    [[ "$(cat add_rules.txt)" =~ "Format: IP_ADDRESS PORT/PROTOCOL COMMENT" ]]
}

@test "Detects duplicate rules in add_rules.txt" {
    cat > add_rules.txt << EOF
192.168.1.100   80/tcp    Web Server
192.168.1.100   80/tcp    Duplicate Entry
EOF
    run bash -c 'source ./ipcoffee.sh && analyze_rules "rules.txt"'
    [[ "${output}" =~ "Duplicate rule detected" ]]
}

@test "Handles empty add_rules.txt" {
    touch add_rules.txt
    run sudo ./ipcoffee.sh -a
    [[ "${output}" =~ "contains no valid rules" ]]
}

@test "Processes comments and empty lines correctly" {
    cat > add_rules.txt << EOF
# This is a comment
192.168.1.100   80/tcp    Web Server

# Another comment
172.16.0.10     443/tcp   HTTPS Server
EOF
    run bash -c 'source ./ipcoffee.sh && handle_add_rules'
    [ "$status" -eq 0 ]
}

# Backup and Restore Tests
@test "Creates backup with correct metadata" {
    setup_ufw_environment
    local backup_file="$BACKUP_DIR/test_backup.txt"
    
    run bash -c "source ./ipcoffee.sh && create_backup ufw '$backup_file'"
    [ -f "$backup_file" ]
    [[ "$(cat $backup_file)" =~ "IPCoffee Firewall Backup" ]]
    [[ "$(cat $backup_file)" =~ "Type:" ]]
    [[ "$(cat $backup_file)" =~ "Date:" ]]
}

@test "Backup files have secure permissions" {
    local backup_file="$BACKUP_DIR/test_backup.txt"
    touch "$backup_file"
    
    run bash -c "source ./ipcoffee.sh && create_backup ufw '$backup_file'"
    [ "$(stat -c %a $backup_file)" = "600" ]
}

@test "Maintains backup rotation limit" {
    # Create 12 backup files
    for i in {1..12}; do
        touch "$BACKUP_DIR/pre_delete_backup_2024010${i}_120000.txt"
    done
    
    run bash -c "source ./ipcoffee.sh && create_backup ufw '$BACKUP_DIR/new_backup.txt' manual"
    
    # Check that only 10 files remain
    [ "$(ls -1 $BACKUP_DIR/pre_delete_backup_* | wc -l)" -eq 10 ]
}

@test "Restore validates backup file existence" {
    run bash -c "source ./ipcoffee.sh && undo_last_deletion ufw"
    [[ "${output}" =~ "No backup found to restore" ]]
}

# Delete Rule Tests
@test "Delete single rule - valid number" {
    setup_ufw_environment
    run sudo ./ipcoffee.sh -d --number 1
    [ "$status" -eq 0 ]
}

@test "Delete single rule - invalid number" {
    run sudo ./ipcoffee.sh -d --number 0
    [ "$status" -eq 1 ]
}

@test "Delete range - valid range" {
    setup_ufw_environment
    run sudo ./ipcoffee.sh -d --range 1-5
    [ "$status" -eq 0 ]
}

@test "Delete range - invalid range format" {
    run sudo ./ipcoffee.sh -d --range 5-3
    [ "$status" -eq 1 ]
    [[ "${output}" =~ "Invalid range" ]]
}

@test "Delete all requires explicit confirmation" {
    run sudo ./ipcoffee.sh -d --all
    [[ "${output}" =~ "Type 'DELETE ALL' to confirm" ]]
}

# SSH Access Tests
@test "Detects existing SSH rules" {
    setup_ufw_environment
    echo "ALLOW IN 22/tcp" > "$TEMP_DIR/ufw_rules"
    
    run bash -c 'source ./ipcoffee.sh && verify_firewall_setup'
    [[ "${output}" =~ "SSH access rules" ]]
}

@test "Warns about missing SSH rules" {
    setup_ufw_environment
    
    run bash -c 'source ./ipcoffee.sh && verify_firewall_setup'
    [[ "${output}" =~ "Warning: No SSH access rules detected" ]]
}

# Menu Navigation Tests
@test "Main menu shows all options" {
    run bash -c 'source ./ipcoffee.sh && show_menu'
    [[ "${output}" =~ "1) Add new firewall rules" ]]
    [[ "${output}" =~ "2) Delete existing rules" ]]
    [[ "${output}" =~ "3) Show current rules" ]]
    [[ "${output}" =~ "4) Exit application" ]]
}

@test "Delete menu shows all options" {
    run bash -c 'source ./ipcoffee.sh && show_delete_menu "ufw" "backup.txt"'
    [[ "${output}" =~ "1) Show current rules" ]]
    [[ "${output}" =~ "2) Delete selected rule(s)" ]]
    [[ "${output}" =~ "3) Delete all rules" ]]
    [[ "${output}" =~ "4) Undo last deletion" ]]
}

# Rule Analysis Tests
@test "Generates detailed rule report" {
    create_test_rules_file
    setup_ufw_environment
    
    run bash -c 'source ./ipcoffee.sh && generate_detailed_report'
    [[ "${output}" =~ "SUMMARY OF RECOMMENDED ACTIONS" ]]
    [[ "${output}" =~ "CRITICAL SYSTEM RULES" ]]
    [[ "${output}" =~ "SAFETY NOTES" ]]
}

@test "Analyzes rule conflicts" {
    create_test_rules_file
    setup_ufw_environment
    
    run bash -c 'source ./ipcoffee.sh && analyze_rules "rules.txt"'
    [[ "${output}" =~ "Rules in your add_rules.txt file that are already active" ]]
    [[ "${output}" =~ "Rules in add_rules.txt that will be added" ]]
}

# Error Handling Tests
@test "Handles missing backup directory gracefully" {
    rm -rf "$BACKUP_DIR"
    run sudo ./ipcoffee.sh
    [ -d "$BACKUP_DIR" ]
}

@test "Handles firewall command failures" {
    create_mock_command "ufw" 1 "Command failed"
    run sudo ./ipcoffee.sh -a
    [ "$status" -ne 0 ]
}

@test "Handles invalid command line arguments" {
    run sudo ./ipcoffee.sh --invalid-option
    [ "$status" -ne 0 ]
}

# Integration Tests
@test "Full workflow - UFW add rules" {
    setup_ufw_environment
    create_test_rules_file
    
    run sudo ./ipcoffee.sh -a
    [ "$status" -eq 0 ]
    [[ "${output}" =~ "Firewall rules have been updated" ]]
}

@test "Full workflow - iptables add rules" {
    setup_iptables_environment
    create_test_rules_file
    
    run sudo ./ipcoffee.sh -a
    [ "$status" -eq 0 ]
    [[ "${output}" =~ "Firewall rules have been updated" ]]
}

@test "Full workflow - backup and restore" {
    setup_ufw_environment
    create_test_rules_file
    
    # Create backup
    run bash -c "source ./ipcoffee.sh && create_backup ufw '$BACKUP_DIR/test_backup.txt'"
    [ "$status" -eq 0 ]
    
    # Restore from backup
    run bash -c "source ./ipcoffee.sh && undo_last_deletion ufw"
    [ "$status" -eq 0 ]
}

