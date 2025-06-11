#!/bin/bash

#==============================================================================
# Kubernetes Maintenance Script - Main Entry Point
# Author: DevOps Engineer
# Description: Comprehensive K8s cluster maintenance and monitoring tool
# Version: 1.0.0
# Date: 2025-06-11
#==============================================================================

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Source all modules
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/health-checks.sh"
source "${SCRIPT_DIR}/lib/kubectl-shortcuts.sh"
source "${SCRIPT_DIR}/lib/node-management.sh"
source "${SCRIPT_DIR}/lib/log-collection.sh"
source "${SCRIPT_DIR}/lib/resource-cleanup.sh"
source "${SCRIPT_DIR}/lib/security-checks.sh"
source "${SCRIPT_DIR}/lib/interactive-menu.sh"

#==============================================================================
# COMMAND LINE INTERFACE
#==============================================================================

# Command line argument parsing
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --health|health)
                cluster_health_check
                exit 0
                ;;
            --security|security)
                security_scan
                exit 0
                ;;
            --cleanup|cleanup)
                cleanup_evicted_pods true
                cleanup_completed_jobs 7 true
                exit 0
                ;;
            --logs|logs)
                collect_critical_logs
                exit 0
                ;;
            --drain)
                shift
                drain_node "$1" true
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "Kubernetes Maintenance Tool v1.0.0"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# Help function
show_help() {
    echo "Kubernetes Maintenance Tool"
    echo
    echo "Usage: $0 [OPTION]"
    echo
    echo "Options:"
    echo "  health          Run cluster health check"
    echo "  security        Run security scan"
    echo "  cleanup         Run resource cleanup"
    echo "  logs            Collect critical logs"
    echo "  --drain NODE    Drain specified node"
    echo "  -h, --help      Show this help"
    echo "  -v, --version   Show version"
    echo
    echo "If no options are provided, the interactive menu will be shown."
}

#==============================================================================
# MAIN EXECUTION
#==============================================================================

main() {
    # Initialize
    initialize
    check_prerequisites
    load_config
    
    # Parse command line arguments
    if [[ $# -gt 0 ]]; then
        parse_arguments "$@"
    else
        # Start interactive menu
        interactive_menu
    fi
}

# Run main function with all arguments
main "$@"