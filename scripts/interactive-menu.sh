#!/bin/bash

#==============================================================================
# Interactive Menu Module
# User-friendly menu system for navigating all functionality
#==============================================================================

# Main menu
show_main_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  Kubernetes Maintenance Tool                 ║"
    echo "║                        Version 1.0.0                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
    echo "Current Cluster: $(kubectl config current-context 2>/dev/null || echo 'Not connected')"
    echo "Log File: $LOG_FILE"
    echo
    echo "Select an option:"
    echo
    echo "1)  📊 Cluster Health Check"
    echo "2)  🏗️  Node Management"
    echo "3)  🚀 Pod Operations"
    echo "4)  📜 Log Collection"
    echo "5)  🧹 Resource Cleanup"
    echo "6)  🔒 Security Scan"
    echo "7)  ⚙️  Configuration"
    echo "8)  📋 View Logs"
    echo "9)  ℹ️  About"
    echo "0)  🚪 Exit"
    echo
}

# Node management submenu
node_management_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== Node Management ===${NC}"
        echo
        echo "1) Check node status"
        echo "2) Drain node"
        echo "3) Cordon node"
        echo "4) Uncordon node"
        echo "5) Check pending pods"
        echo "6) Show node details"
        echo "7) Monitor node resources"
        echo "8) Check node disk usage"
        echo "9) Back to main menu"
        echo
        
        read -p "Select option: " choice
        
        case $choice in
            1) 
                check_node_status
                read -p "Press Enter to continue..."
                ;;
            2) 
                echo "Available nodes:"
                kubectl get nodes --no-headers | awk '{print "  " $1}'
                echo
                read -p "Enter node name: " node
                if [[ -n "$node" ]]; then
                    read -p "Force drain? (y/N): " force
                    [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                    drain_node "$node" "$force"
                fi
                read -p "Press Enter to continue..."
                ;;
            3)
                echo "Available nodes:"
                kubectl get nodes --no-headers | awk '{print "  " $1}'
                echo
                read -p "Enter node name: " node
                if [[ -n "$node" ]]; then
                    cordon_node "$node" "cordon"
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                echo "Cordoned nodes:"
                kubectl get nodes --no-headers | grep SchedulingDisabled | awk '{print "  " $1}'
                echo
                read -p "Enter node name: " node
                if [[ -n "$node" ]]; then
                    cordon_node "$node" "uncordon"
                fi
                read -p "Press Enter to continue..."
                ;;
            5) 
                check_pending_pods
                read -p "Press Enter to continue..."
                ;;
            6)
                echo "Available nodes:"
                kubectl get nodes --no-headers | awk '{print "  " $1}'
                echo
                read -p "Enter node name: " node
                if [[ -n "$node" ]]; then
                    show_node_details "$node"
                fi
                read -p "Press Enter to continue..."
                ;;
            7)
                echo "Available nodes:"
                kubectl get nodes --no-headers | awk '{print "  " $1}'
                echo
                read -p "Enter node name: " node
                if [[ -n "$node" ]]; then
                    read -p "Duration in seconds (60): " duration
                    duration=${duration:-60}
                    read -p "Interval in seconds (5): " interval
                    interval=${interval:-5}
                    monitor_node_resources "$node" "$duration" "$interval"
                fi
                read -p "Press Enter to continue..."
                ;;
            8)
                echo "Available nodes:"
                kubectl get nodes --no-headers | awk '{print "  " $1}'
                echo
                read -p "Enter node name: " node
                if [[ -n "$node" ]]; then
                    check_node_disk_usage "$node"
                fi
                read -p "Press Enter to continue..."
                ;;
            9) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Pod operations submenu
pod_operations_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== Pod Operations ===${NC}"
        echo
        echo "1) Get pod logs"
        echo "2) Execute command in pod"
        echo "3) Port forward"
        echo "4) Check pod distribution"
        echo "5) Pod status by namespace"
        echo "6) Resource usage by namespace"
        echo "7) Copy files to/from pod"
        echo "8) Get pod events"
        echo "9) Namespace overview"
        echo "10) Back to main menu"
        echo
        
        read -p "Select option: " choice
        
        case $choice in
            1)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                read -p "Enter pod pattern: " pattern
                if [[ -n "$pattern" ]]; then
                    read -p "Number of lines (100): " lines
                    lines=${lines:-100}
                    kube_logs "$namespace" "$pattern" "$lines"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                read -p "Enter pod pattern: " pattern
                if [[ -n "$pattern" ]]; then
                    read -p "Command (/bin/bash): " command
                    command=${command:-/bin/bash}
                    kube_exec "$namespace" "$pattern" "$command"
                fi
                ;;
            3)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                read -p "Enter pod pattern: " pattern
                if [[ -n "$pattern" ]]; then
                    read -p "Local port: " local_port
                    read -p "Remote port: " remote_port
                    if [[ -n "$local_port" && -n "$remote_port" ]]; then
                        kube_port_forward "$namespace" "$pattern" "$local_port" "$remote_port"
                    fi
                fi
                ;;
            4) 
                check_pod_distribution
                read -p "Press Enter to continue..."
                ;;
            5)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                kube_pod_status "$namespace"
                read -p "Press Enter to continue..."
                ;;
            6)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                kube_resource_usage "$namespace"
                read -p "Press Enter to continue..."
                ;;
            7)
                echo "Copy direction: 'to' (local->pod) or 'from' (pod->local)"
                read -p "Direction (to/from): " direction
                if [[ "$direction" == "to" || "$direction" == "from" ]]; then
                    read -p "Enter namespace (default): " namespace
                    namespace=${namespace:-default}
                    read -p "Enter pod pattern: " pattern
                    read -p "Source path: " source
                    read -p "Destination path: " destination
                    if [[ -n "$pattern" && -n "$source" && -n "$destination" ]]; then
                        kube_copy "$direction" "$namespace" "$pattern" "$source" "$destination"
                    fi
                fi
                read -p "Press Enter to continue..."
                ;;
            8)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                read -p "Enter resource name (optional): " resource
                kube_events "$namespace" "$resource"
                read -p "Press Enter to continue..."
                ;;
            9)
                read -p "Enter namespace (default): " namespace
                namespace=${namespace:-default}
                kube_namespace_overview "$namespace"
                read -p "Press Enter to continue..."
                ;;
            10) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Log collection submenu
log_collection_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== Log Collection ===${NC}"
        echo
        echo "1) Collect critical pod logs"
        echo "2) Collect problematic pod logs"
        echo "3) Collect systemd logs"
        echo "4) Collect logs by time range"
        echo "5) Collect cluster events"
        echo "6) Collect application logs"
        echo "7) Generate log summary"
        echo "8) Clean old logs"
        echo "9) Back to main menu"
        echo
        
        read -p "Select option: " choice
        
        case $choice in
            1)
                read -p "Output directory ($TEMP_DIR/logs): " output_dir
                output_dir=${output_dir:-$TEMP_DIR/logs}
                read -p "Number of lines (1000): " lines
                lines=${lines:-1000}
                collect_critical_logs "$output_dir" "$lines"
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Output directory ($TEMP_DIR/problematic_logs): " output_dir
                output_dir=${output_dir:-$TEMP_DIR/problematic_logs}
                collect_problematic_pod_logs "$output_dir"
                read -p "Press Enter to continue..."
                ;;
            3)
                read -p "Service name (kubelet): " service
                service=${service:-kubelet}
                read -p "Number of lines (1000): " lines
                lines=${lines:-1000}
                collect_systemd_logs "$service" "$lines"
                read -p "Press Enter to continue..."
                ;;
            4)
                read -p "Namespace (default): " namespace
                namespace=${namespace:-default}
                read -p "Pod pattern: " pattern
                if [[ -n "$pattern" ]]; then
                    read -p "Since (1h): " since
                    since=${since:-1h}
                    collect_logs_by_timerange "$namespace" "$pattern" "$since"
                fi
                read -p "Press Enter to continue..."
                ;;
            5)
                read -p "Since (1h): " since
                since=${since:-1h}
                collect_cluster_events "$TEMP_DIR/events" "$since"
                read -p "Press Enter to continue..."
                ;;
            6)
                read -p "Namespace: " namespace
                read -p "App label: " app_label
                if [[ -n "$namespace" && -n "$app_label" ]]; then
                    read -p "Grep pattern (ERROR): " pattern
                    pattern=${pattern:-ERROR}
                    collect_application_logs "$namespace" "$app_label" "$pattern"
                fi
                read -p "Press Enter to continue..."
                ;;
            7)
                generate_log_summary
                read -p "Press Enter to continue..."
                ;;
            8)
                read -p "Days to keep (7): " days
                days=${days:-7}
                cleanup_old_logs "$TEMP_DIR" "$days"
                read -p "Press Enter to continue..."
                ;;
            9) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Resource cleanup submenu
resource_cleanup_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== Resource Cleanup ===${NC}"
        echo
        echo "1) Cleanup evicted pods"
        echo "2) Cleanup completed jobs"
        echo "3) Cleanup failed jobs"
        echo "4) Cleanup unused ConfigMaps"
        echo "5) Cleanup unused Secrets"
        echo "6) Cleanup orphaned PVCs"
        echo "7) Cleanup terminated pods"
        echo "8) Comprehensive cleanup"
        echo "9) Back to main menu"
        echo
        
        read -p "Select option: " choice
        
        case $choice in
            1)
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_evicted_pods "$force"
                read -p "Press Enter to continue..."
                ;;
            2)
                read -p "Retention days (7): " days
                days=${days:-7}
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_completed_jobs "$days" "$force"
                read -p "Press Enter to continue..."
                ;;
            3)
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_failed_jobs "$force"
                read -p "Press Enter to continue..."
                ;;
            4)
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_unused_resources "$force" "configmap"
                read -p "Press Enter to continue..."
                ;;
            5)
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_unused_resources "$force" "secret"
                read -p "Press Enter to continue..."
                ;;
            6)
                echo -e "${RED}WARNING: This will delete PVCs and underlying storage!${NC}"
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_orphaned_pvcs "$force"
                read -p "Press Enter to continue..."
                ;;
            7)
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                cleanup_terminated_pods "$force"
                read -p "Press Enter to continue..."
                ;;
            8)
                echo -e "${YELLOW}This will run all enabled cleanup operations${NC}"
                read -p "Force cleanup without prompts? (y/N): " force
                [[ "$force" == "y" || "$force" == "Y" ]] && force="true" || force="false"
                comprehensive_cleanup "$force"
                read -p "Press Enter to continue..."
                ;;
            9) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Configuration management submenu
configuration_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== Configuration Management ===${NC}"
        echo
        echo "Configuration file: $CONFIG_FILE"
        echo "Log file: $LOG_FILE"
        echo
        echo "1) View current configuration"
        echo "2) Edit configuration file"
        echo "3) Reset to default configuration"
        echo "4) Validate configuration"
        echo "5) Show configuration paths"
        echo "6) Back to main menu"
        echo
        
        read -p "Select option: " choice
        
        case $choice in
            1)
                echo -e "\n${CYAN}=== Current Configuration ===${NC}"
                if [[ -f "$CONFIG_FILE" ]]; then
                    cat "$CONFIG_FILE"
                else
                    echo "Configuration file not found"
                fi
                read -p "Press Enter to continue..."
                ;;
            2)
                if command -v nano &> /dev/null; then
                    nano "$CONFIG_FILE"
                elif command -v vi &> /dev/null; then
                    vi "$CONFIG_FILE"
                else
                    echo "No editor found. Please edit $CONFIG_FILE manually"
                fi
                # Reload configuration
                load_config
                read -p "Press Enter to continue..."
                ;;
            3)
                if confirm_action "Reset configuration to defaults?"; then
                    echo "$DEFAULT_CONFIG" | yq eval -P > "$CONFIG_FILE"
                    load_config
                    echo "Configuration reset to defaults"
                fi
                read -p "Press Enter to continue..."
                ;;
            4)
                echo -e "\n${CYAN}=== Configuration Validation ===${NC}"
                if yq eval "$CONFIG_FILE" > /dev/null 2>&1; then
                    echo -e "${GREEN}Configuration file is valid YAML${NC}"
                else
                    echo -e "${RED}Configuration file has YAML syntax errors${NC}"
                fi
                read -p "Press Enter to continue..."
                ;;
            5)
                echo -e "\n${CYAN}=== Configuration Paths ===${NC}"
                echo "Script directory: $SCRIPT_DIR"
                echo "Configuration file: $CONFIG_FILE"
                echo "Log file: $LOG_FILE"
                echo "Temporary directory: $TEMP_DIR"
                read -p "Press Enter to continue..."
                ;;
            6) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Main interactive menu loop
interactive_menu() {
    while true; do
        show_main_menu
        read -p "Enter your choice: " choice
        
        case $choice in
            1) 
                cluster_health_check
                read -p "Press Enter to continue..."
                ;;
            2) node_management_menu ;;
            3) pod_operations_menu ;;
            4) log_collection_menu ;;
            5) resource_cleanup_menu ;;
            6) 
                security_scan
                read -p "Press Enter to continue..."
                ;;
            7) configuration_menu ;;
            8) 
                echo -e "\n${CYAN}=== Recent Log Entries ===${NC}"
                tail -30 "$LOG_FILE" 2>/dev/null || echo "No log entries found"
                read -p "Press Enter to continue..."
                ;;
            9)
                clear
                echo -e "${CYAN}"
                echo "╔══════════════════════════════════════════════════════════════╗"
                echo "║                  Kubernetes Maintenance Tool                 ║"
                echo "║                        Version 1.0.0                         ║"
                echo "╚══════════════════════════════════════════════════════════════╝"
                echo -e "${NC}"
                echo
                echo "A comprehensive DevOps tool for Kubernetes cluster maintenance"
                echo
                echo "Features:"
                echo "• 📊 Cluster health monitoring and resource utilization checks"
                echo "• 🏗️  Safe node maintenance operations (drain, cordon, uncordon)"
                echo "• 🚀 Enhanced kubectl shortcuts with error handling"
                echo "• 📜 Automated log collection and archival"
                echo "• 🧹 Resource cleanup with customizable retention policies"
                echo "• 🔒 Security vulnerability scanning and RBAC analysis"
                echo "• ⚙️  Configurable thresholds and excluded namespaces"
                echo "• 📋 Comprehensive audit logging"
                echo
                echo "Files:"
                echo "• Configuration: $CONFIG_FILE"
                echo "• Log file: $LOG_FILE"
                echo "• Script directory: $SCRIPT_DIR"
                echo
                echo "Author: DevOps Engineer"
                echo "Date: 2025-06-11"
                read -p "Press Enter to continue..."
                ;;
            0) 
                log "INFO" "Exiting Kubernetes Maintenance Tool"
                echo -e "\n${GREEN}Thank you for using the Kubernetes Maintenance Tool!${NC}"
                echo "Check the log file for a complete audit trail: $LOG_FILE"
                exit 0
                ;;
            *) 
                echo -e "${RED}Invalid option. Please try again.${NC}"
                sleep 1
                ;;
        esac
    done
}