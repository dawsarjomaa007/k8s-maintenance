#!/bin/bash

#==============================================================================
# Kubernetes Maintenance Script - Main Entry Point
# Author: DevOps Engineer
# Description: Comprehensive K8s cluster maintenance and monitoring tool
# Version: 1.0.0
# Date: 2025-06-11
#==============================================================================

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Source enhanced modules with error handling
source "${SCRIPT_DIR}/scripts/error-handler.sh"
source "${SCRIPT_DIR}/scripts/utils.sh"
source "${SCRIPT_DIR}/scripts/config.sh"
source "${SCRIPT_DIR}/scripts/health-checks.sh"
source "${SCRIPT_DIR}/scripts/kubectl-shortcuts.sh"
source "${SCRIPT_DIR}/scripts/node-management.sh"
source "${SCRIPT_DIR}/scripts/log-collection.sh"
source "${SCRIPT_DIR}/scripts/resource-cleanup.sh"
source "${SCRIPT_DIR}/scripts/security-checks.sh"
source "${SCRIPT_DIR}/scripts/interactive-menu.sh"

#==============================================================================
# ENHANCED COMMAND LINE INTERFACE WITH ERROR HANDLING
#==============================================================================

# Enhanced command line argument parsing with error handling
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --health|health)
                safe_execute cluster_health_check "Health check failed" || exit $?
                clear_rollback_stack
                exit $E_SUCCESS
                ;;
            --security|security)
                safe_execute security_scan "Security scan failed" || exit $?
                clear_rollback_stack
                exit $E_SUCCESS
                ;;
            --cleanup|cleanup)
                log_info "Starting cleanup operations..."
                safe_execute cleanup_evicted_pods "Evicted pods cleanup failed" true || log_warn "Some cleanup operations failed"
                safe_execute cleanup_completed_jobs "Completed jobs cleanup failed" 7 true || log_warn "Job cleanup had issues"
                clear_rollback_stack
                exit $E_SUCCESS
                ;;
            --logs|logs)
                safe_execute collect_critical_logs "Log collection failed" || exit $?
                clear_rollback_stack
                exit $E_SUCCESS
                ;;
            --drain)
                shift
                if [[ -z "$1" ]]; then
                    log_error "Node name required for drain operation"
                    show_help
                    exit $E_VALIDATION_ERROR
                fi
                validate_resource_name "$1" "node" || exit $?
                safe_execute drain_node "Node drain failed" "$1" true || exit $?
                clear_rollback_stack
                exit $E_SUCCESS
                ;;
            --config-check)
                safe_execute config_health_check "Configuration check failed" || exit $?
                exit $E_SUCCESS
                ;;
            --circuit-breaker-status)
                show_circuit_breaker_status
                exit $E_SUCCESS
                ;;
            --dry-run)
                export DRY_RUN=true
                log_info "Dry-run mode enabled"
                ;;
            --debug)
                export K8S_MAINTENANCE_DEBUG=true
                log_info "Debug mode enabled"
                ;;
            --force)
                export FORCE_OPERATIONS=true
                log_warn "Force mode enabled - safety checks may be bypassed"
                ;;
            --help|-h)
                show_help
                exit $E_SUCCESS
                ;;
            --version|-v)
                echo "Kubernetes Maintenance Tool v1.0.0"
                echo "Error Handling: Enhanced with circuit breakers and retry logic"
                exit $E_SUCCESS
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit $E_VALIDATION_ERROR
                ;;
        esac
        shift
    done
}

# Enhanced help function
show_help() {
    cat << EOF
Kubernetes Maintenance Tool v1.0.0
===================================

Usage: $0 [OPTION]

MAIN OPERATIONS:
  health              Run comprehensive cluster health check
  security            Run security vulnerability scan
  cleanup             Run automated resource cleanup
  logs                Collect critical system logs
  --drain NODE        Drain specified node safely

CONFIGURATION:
  --config-check      Validate configuration and secrets
  --circuit-breaker-status  Show circuit breaker status

EXECUTION MODES:
  --dry-run           Preview operations without executing
  --debug             Enable verbose debug logging
  --force             Bypass safety confirmations (use with caution)

INFORMATION:
  -h, --help          Show this help message
  -v, --version       Show version and feature information

EXAMPLES:
  $0                           # Interactive menu
  $0 health --debug            # Health check with debug output
  $0 cleanup --dry-run         # Preview cleanup operations
  $0 --drain worker-1 --force  # Force drain node without confirmation

ERROR HANDLING FEATURES:
  • Automatic retry with exponential backoff
  • Circuit breaker protection for API calls
  • Comprehensive rollback on failures
  • Graceful handling of interruptions

ENVIRONMENT VARIABLES:
  K8S_ENV                     Environment (development/staging/production)
  K8S_MAINTENANCE_DEBUG       Enable debug mode (true/false)
  K8S_MAINTENANCE_DRY_RUN     Enable dry-run mode (true/false)
  FORCE_DEFAULT_CONFIG        Use default config on validation failure

If no options are provided, the interactive menu will be shown.
EOF
}

#==============================================================================
# ENHANCED MAIN EXECUTION WITH COMPREHENSIVE ERROR HANDLING
#==============================================================================

main() {
    local exit_code=$E_SUCCESS
    
    # Initialize with enhanced error handling
    if ! safe_execute initialize "Initialization failed"; then
        echo "FATAL: Failed to initialize maintenance tool" >&2
        exit $E_GENERAL_ERROR
    fi
    
    # Check prerequisites with retry and circuit breaker
    if ! safe_execute check_prerequisites "Prerequisites check failed"; then
        log_error "Prerequisites check failed. Cannot continue."
        exit $E_CONFIG_ERROR
    fi
    
    # Initialize configuration system
    if ! safe_execute init_config "Configuration initialization failed"; then
        if [[ "${FORCE_DEFAULT_CONFIG:-false}" != "true" ]]; then
            log_error "Configuration initialization failed. Set FORCE_DEFAULT_CONFIG=true to use defaults."
            exit $E_CONFIG_ERROR
        fi
        log_warn "Using default configuration due to initialization failure"
    fi
    
    # Parse command line arguments with error handling
    if [[ $# -gt 0 ]]; then
        parse_arguments "$@"
    else
        # Start interactive menu with error handling
        if ! safe_execute interactive_menu "Interactive menu failed"; then
            log_error "Interactive menu encountered an error"
            exit_code=$E_GENERAL_ERROR
        fi
    fi
    
    # Clear rollback stack on successful completion
    clear_rollback_stack
    
    log_info "=== Kubernetes Maintenance Script Completed ==="
    exit $exit_code
}

# Enhanced signal handling
handle_script_interrupt() {
    log_warn "Script interrupted by signal"
    execute_rollback_stack
    cleanup_on_error
    exit 130
}

# Set up signal handlers before main execution
trap 'handle_script_interrupt' SIGINT SIGTERM

# Run main function with all arguments, capturing any unhandled errors
if ! main "$@"; then
    exit_code=$?
    log_error "Script execution failed with exit code: $exit_code"
    exit $exit_code
fi