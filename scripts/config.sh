#!/bin/bash

#==============================================================================
# Enhanced Configuration Management Module
# Handles loading, validation, and parsing of configuration files
# Supports environment-specific configs and secrets management
#==============================================================================

# Source dependencies
source "${SCRIPT_DIR}/scripts/config-validator.sh"
source "${SCRIPT_DIR}/scripts/secrets-manager.sh"

# Default configuration
DEFAULT_CONFIG='{
  "environment": "development",
  "thresholds": {
    "cpu_warning": 80,
    "memory_warning": 85,
    "disk_warning": 90,
    "pod_restart_threshold": 10
  },
  "excluded_namespaces": ["kube-system", "kube-public", "kube-node-lease"],
  "retention_days": 7,
  "log_lines": 1000,
  "security_checks": true,
  "auto_cleanup": false
}'

# Configuration file paths
ENVIRONMENT="${K8S_ENV:-development}"
CONFIG_FILE="${SCRIPT_DIR}/k8s-config.yaml"
ENV_CONFIG_FILE="${SCRIPT_DIR}/configs/k8s-config-${ENVIRONMENT}.yaml"
BASELINE_CONFIG="${SCRIPT_DIR}/k8s-config-baseline.yaml"
LOG_FILE="${SCRIPT_DIR}/k8s-maintenance.log"
TEMP_DIR="/tmp/k8s-maintenance-$$"

# Global configuration variable
CONFIG=""

# Initialize configuration system
init_config() {
    log_info "Initializing configuration system for environment: $ENVIRONMENT"
    
    # Initialize secrets management
    init_secrets
    
    # Load configuration with validation
    load_config_with_validation
    
    # Load secrets
    load_secrets
    
    # Detect configuration drift
    if [[ -f "$BASELINE_CONFIG" ]]; then
        detect_config_drift "$CONFIG_FILE" "$BASELINE_CONFIG"
    fi
}

# Load configuration with comprehensive validation
load_config_with_validation() {
    local config_to_load=""
    
    # Determine which config file to use
    if [[ -f "$ENV_CONFIG_FILE" ]]; then
        config_to_load="$ENV_CONFIG_FILE"
        log_info "Using environment-specific config: $ENV_CONFIG_FILE"
    elif [[ -f "$CONFIG_FILE" ]]; then
        config_to_load="$CONFIG_FILE"
        log_info "Using default config: $CONFIG_FILE"
    else
        log_warn "No configuration file found, creating default"
        create_default_config
        config_to_load="$CONFIG_FILE"
    fi
    
    # Validate configuration
    if validate_config "$config_to_load"; then
        log_info "Configuration validation passed"
        
        # Load the validated configuration
        CONFIG=$(yq eval -o=json "$config_to_load")
        
        # Process environment variable substitutions
        CONFIG=$(process_env_substitutions "$CONFIG")
        
    else
        log_error "Configuration validation failed"
        
        # Offer to use defaults or exit
        if [[ "${FORCE_DEFAULT_CONFIG:-false}" == "true" ]]; then
            log_warn "Using default configuration due to validation failure"
            CONFIG="$DEFAULT_CONFIG"
        else
            log_error "Refusing to start with invalid configuration. Set FORCE_DEFAULT_CONFIG=true to override."
            exit 1
        fi
    fi
}

# Create default configuration file
create_default_config() {
    log_info "Creating default configuration file: $CONFIG_FILE"
    
    cat > "$CONFIG_FILE" << EOF
# Kubernetes Maintenance Tool Configuration
# Generated: $(date)

environment: $ENVIRONMENT

thresholds:
  cpu_warning: 80
  memory_warning: 85
  disk_warning: 90
  pod_restart_threshold: 10

excluded_namespaces:
  - kube-system
  - kube-public
  - kube-node-lease

retention_days: 7
log_lines: 1000
security_checks: true
auto_cleanup: false
EOF
}

# Process environment variable substitutions
process_env_substitutions() {
    local config_json="$1"
    
    # Load secrets first
    load_secrets
    
    # Replace ${VAR_NAME} patterns with actual values
    # This is a simple implementation - production might use envsubst or similar
    local processed_config="$config_json"
    
    # Common substitutions
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        processed_config=$(echo "$processed_config" | sed "s|\${SLACK_WEBHOOK_URL}|$SLACK_WEBHOOK_URL|g")
    fi
    
    echo "$processed_config"
}

# Get configuration value with fallback
get_config() {
    local key="$1"
    local default_value="$2"
    
    if [[ -z "$CONFIG" ]]; then
        log_error "Configuration not loaded. Call init_config first."
        return 1
    fi
    
    local value
    value=$(echo "$CONFIG" | jq -r ".$key // empty")
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        if [[ -n "$default_value" ]]; then
            echo "$default_value"
        else
            echo ""
        fi
    else
        echo "$value"
    fi
}

# Get array configuration values
get_config_array() {
    local key="$1"
    
    if [[ -z "$CONFIG" ]]; then
        log_error "Configuration not loaded. Call init_config first."
        return 1
    fi
    
    echo "$CONFIG" | jq -r ".$key[]? // empty"
}

# Check if configuration key exists
config_has_key() {
    local key="$1"
    
    if [[ -z "$CONFIG" ]]; then
        return 1
    fi
    
    echo "$CONFIG" | jq -e "has(\"$key\")" >/dev/null 2>&1
}

# Get environment-specific configuration
get_env_config() {
    local key="$1"
    local environment="${2:-$ENVIRONMENT}"
    
    # Try environment-specific value first
    local env_key="environments.${environment}.${key}"
    local value
    value=$(get_config "$env_key")
    
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        # Fallback to global value
        get_config "$key"
    fi
}

# Validate current environment
validate_environment() {
    local valid_environments=("development" "staging" "production" "local")
    
    for env in "${valid_environments[@]}"; do
        if [[ "$ENVIRONMENT" == "$env" ]]; then
            return 0
        fi
    done
    
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Valid environments: ${valid_environments[*]}"
    return 1
}

# Switch environment
switch_environment() {
    local new_env="$1"
    
    if [[ -z "$new_env" ]]; then
        echo "ERROR: Environment name required"
        return 1
    fi
    
    # Validate new environment
    local temp_env="$ENVIRONMENT"
    ENVIRONMENT="$new_env"
    
    if ! validate_environment; then
        ENVIRONMENT="$temp_env"
        return 1
    fi
    
    log_info "Switching to environment: $new_env"
    
    # Reload configuration for new environment
    init_config
    
    log_info "Successfully switched to environment: $new_env"
}

# Update configuration value
update_config() {
    local key="$1"
    local value="$2"
    local config_file="${3:-$CONFIG_FILE}"
    
    if [[ -z "$key" || -z "$value" ]]; then
        echo "ERROR: Both key and value required"
        return 1
    fi
    
    # Create backup
    cp "$config_file" "${config_file}.bak"
    
    # Update using yq
    yq eval ".$key = \"$value\"" -i "$config_file"
    
    # Validate updated configuration
    if validate_config "$config_file"; then
        log_info "Updated configuration: $key = $value"
        # Reload configuration
        init_config
    else
        # Restore backup
        mv "${config_file}.bak" "$config_file"
        log_error "Failed to update configuration. Restored backup."
        return 1
    fi
}

# Show current configuration
show_config() {
    local format="${1:-yaml}"
    
    if [[ -z "$CONFIG" ]]; then
        log_error "Configuration not loaded"
        return 1
    fi
    
    case "$format" in
        "json")
            echo "$CONFIG" | jq .
            ;;
        "yaml")
            echo "$CONFIG" | yq eval -P
            ;;
        "table")
            show_config_table
            ;;
        *)
            log_error "Invalid format: $format. Use json, yaml, or table"
            return 1
            ;;
    esac
}

# Show configuration in table format
show_config_table() {
    echo "Configuration Summary"
    echo "===================="
    echo "Environment: $(get_config "environment")"
    echo "Cluster: $(get_config "cluster.name")"
    echo "Context: $(get_config "cluster.context")"
    echo ""
    echo "Thresholds:"
    echo "  CPU Warning: $(get_config "thresholds.cpu_warning")%"
    echo "  Memory Warning: $(get_config "thresholds.memory_warning")%"
    echo "  Disk Warning: $(get_config "thresholds.disk_warning")%"
    echo ""
    echo "Settings:"
    echo "  Retention Days: $(get_config "retention_days")"
    echo "  Security Checks: $(get_config "security_checks")"
    echo "  Auto Cleanup: $(get_config "auto_cleanup")"
    echo ""
    echo "Excluded Namespaces:"
    get_config_array "excluded_namespaces" | sed 's/^/  - /'
}

# Configuration health check
config_health_check() {
    local issues=()
    
    log_info "Performing configuration health check..."
    
    # Check if configuration is loaded
    if [[ -z "$CONFIG" ]]; then
        issues+=("Configuration not loaded")
    fi
    
    # Check environment validity
    if ! validate_environment; then
        issues+=("Invalid environment: $ENVIRONMENT")
    fi
    
    # Check configuration file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        issues+=("Configuration file missing: $CONFIG_FILE")
    fi
    
    # Validate configuration
    if ! validate_config "$CONFIG_FILE"; then
        issues+=("Configuration validation failed")
    fi
    
    # Check secrets
    if ! validate_secrets; then
        issues+=("Secrets validation failed")
    fi
    
    # Report results
    if [[ ${#issues[@]} -eq 0 ]]; then
        log_info "Configuration health check passed"
        return 0
    else
        log_error "Configuration health check failed:"
        printf "  - %s\n" "${issues[@]}"
        return 1
    fi
}

# Cleanup configuration system
cleanup_config() {
    # Clean up temporary files
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    
    # Clean up secrets from memory
    cleanup_secrets
    
    log_debug "Configuration system cleaned up"
}