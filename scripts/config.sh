#!/bin/bash

#==============================================================================
# Configuration Management Module
# Handles loading and parsing of configuration files
#==============================================================================

# Default configuration
DEFAULT_CONFIG='{
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
CONFIG_FILE="${SCRIPT_DIR}/k8s-config.yaml"
LOG_FILE="${SCRIPT_DIR}/k8s-maintenance.log"
TEMP_DIR="/tmp/k8s-maintenance-$$"

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        CONFIG=$(yq eval -o=json "$CONFIG_FILE")
    else
        log "WARN" "Config file not found, using defaults"
        CONFIG="$DEFAULT_CONFIG"
        echo "$DEFAULT_CONFIG" | yq eval -P > "$CONFIG_FILE"
        log "INFO" "Created default config file: $CONFIG_FILE"
    fi
}

# Get config value
get_config() {
    local key="$1"
    echo "$CONFIG" | jq -r ".$key // empty"
}