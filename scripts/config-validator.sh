#!/bin/bash

#==============================================================================
# Configuration Schema Validator
# Validates k8s-config.yaml against defined schemas and rules
#==============================================================================

# Configuration schema definition
CONFIG_SCHEMA='{
  "type": "object",
  "required": ["thresholds", "excluded_namespaces", "retention_days"],
  "properties": {
    "environment": {
      "type": "string",
      "enum": ["development", "staging", "production", "local"]
    },
    "cluster": {
      "type": "object",
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "context": {"type": "string", "minLength": 1},
        "region": {"type": "string"}
      }
    },
    "thresholds": {
      "type": "object",
      "required": ["cpu_warning", "memory_warning", "disk_warning"],
      "properties": {
        "cpu_warning": {"type": "number", "minimum": 1, "maximum": 100},
        "memory_warning": {"type": "number", "minimum": 1, "maximum": 100},
        "disk_warning": {"type": "number", "minimum": 1, "maximum": 100},
        "pod_restart_threshold": {"type": "number", "minimum": 1, "maximum": 1000}
      }
    },
    "excluded_namespaces": {
      "type": "array",
      "items": {"type": "string", "minLength": 1},
      "minItems": 1
    },
    "retention_days": {"type": "number", "minimum": 1, "maximum": 365},
    "log_lines": {"type": "number", "minimum": 100, "maximum": 100000},
    "security_checks": {"type": "boolean"},
    "auto_cleanup": {"type": "boolean"},
    "backup": {
      "type": "object",
      "properties": {
        "enabled": {"type": "boolean"},
        "retention_count": {"type": "number", "minimum": 1, "maximum": 100},
        "storage_path": {"type": "string"}
      }
    },
    "alerts": {
      "type": "object",
      "properties": {
        "enabled": {"type": "boolean"},
        "webhook_url": {"type": "string", "format": "uri"},
        "channels": {
          "type": "array",
          "items": {"type": "string"}
        }
      }
    },
    "timeouts": {
      "type": "object",
      "properties": {
        "kubectl_timeout": {"type": "number", "minimum": 5, "maximum": 300},
        "drain_timeout": {"type": "number", "minimum": 60, "maximum": 3600},
        "health_check_timeout": {"type": "number", "minimum": 10, "maximum": 600}
      }
    }
  }
}'

# Validate configuration file
validate_config() {
    local config_file="$1"
    local errors=()
    
    log_info "Validating configuration file: $config_file"
    
    # Check if file exists
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file"
        return 1
    fi
    
    # Check YAML syntax
    if ! yq eval '.' "$config_file" >/dev/null 2>&1; then
        echo "ERROR: Invalid YAML syntax in $config_file"
        return 1
    fi
    
    # Convert to JSON for validation
    local config_json
    config_json=$(yq eval -o=json "$config_file" 2>/dev/null)
    
    if [[ -z "$config_json" ]]; then
        echo "ERROR: Failed to parse YAML configuration"
        return 1
    fi
    
    # Validate against schema using jq
    validate_schema_with_jq "$config_json"
    local schema_result=$?
    
    # Custom business logic validation
    validate_business_rules "$config_json"
    local business_result=$?
    
    if [[ $schema_result -eq 0 && $business_result -eq 0 ]]; then
        log_info "Configuration validation passed"
        return 0
    else
        log_error "Configuration validation failed"
        return 1
    fi
}

# Schema validation using jq
validate_schema_with_jq() {
    local config_json="$1"
    local errors=()
    
    # Check required fields
    local required_fields=("thresholds" "excluded_namespaces" "retention_days")
    for field in "${required_fields[@]}"; do
        if ! echo "$config_json" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
            errors+=("Missing required field: $field")
        fi
    done
    
    # Validate thresholds
    local cpu_warning memory_warning disk_warning
    cpu_warning=$(echo "$config_json" | jq -r '.thresholds.cpu_warning // empty')
    memory_warning=$(echo "$config_json" | jq -r '.thresholds.memory_warning // empty')
    disk_warning=$(echo "$config_json" | jq -r '.thresholds.disk_warning // empty')
    
    if [[ -n "$cpu_warning" ]]; then
        if [[ ! "$cpu_warning" =~ ^[0-9]+$ ]] || [[ $cpu_warning -lt 1 ]] || [[ $cpu_warning -gt 100 ]]; then
            errors+=("Invalid cpu_warning threshold: must be 1-100")
        fi
    fi
    
    if [[ -n "$memory_warning" ]]; then
        if [[ ! "$memory_warning" =~ ^[0-9]+$ ]] || [[ $memory_warning -lt 1 ]] || [[ $memory_warning -gt 100 ]]; then
            errors+=("Invalid memory_warning threshold: must be 1-100")
        fi
    fi
    
    if [[ -n "$disk_warning" ]]; then
        if [[ ! "$disk_warning" =~ ^[0-9]+$ ]] || [[ $disk_warning -lt 1 ]] || [[ $disk_warning -gt 100 ]]; then
            errors+=("Invalid disk_warning threshold: must be 1-100")
        fi
    fi
    
    # Validate retention days
    local retention_days
    retention_days=$(echo "$config_json" | jq -r '.retention_days // empty')
    if [[ -n "$retention_days" ]]; then
        if [[ ! "$retention_days" =~ ^[0-9]+$ ]] || [[ $retention_days -lt 1 ]] || [[ $retention_days -gt 365 ]]; then
            errors+=("Invalid retention_days: must be 1-365")
        fi
    fi
    
    # Print errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "Schema validation errors:"
        printf "  - %s\n" "${errors[@]}"
        return 1
    fi
    
    return 0
}

# Business rules validation
validate_business_rules() {
    local config_json="$1"
    local warnings=()
    local errors=()
    
    # Check if thresholds are sensible
    local cpu_warning memory_warning disk_warning
    cpu_warning=$(echo "$config_json" | jq -r '.thresholds.cpu_warning // 80')
    memory_warning=$(echo "$config_json" | jq -r '.thresholds.memory_warning // 85')
    disk_warning=$(echo "$config_json" | jq -r '.thresholds.disk_warning // 90')
    
    if [[ $cpu_warning -gt 95 ]]; then
        warnings+=("CPU warning threshold very high ($cpu_warning%). Consider lowering.")
    fi
    
    if [[ $memory_warning -gt 95 ]]; then
        warnings+=("Memory warning threshold very high ($memory_warning%). Consider lowering.")
    fi
    
    if [[ $disk_warning -gt 95 ]]; then
        warnings+=("Disk warning threshold very high ($disk_warning%). Consider lowering.")
    fi
    
    # Check environment-specific rules
    local environment
    environment=$(echo "$config_json" | jq -r '.environment // "development"')
    
    case "$environment" in
        "production")
            local auto_cleanup
            auto_cleanup=$(echo "$config_json" | jq -r '.auto_cleanup // false')
            if [[ "$auto_cleanup" == "true" ]]; then
                errors+=("auto_cleanup should be disabled in production environment")
            fi
            ;;
        "development")
            local retention_days
            retention_days=$(echo "$config_json" | jq -r '.retention_days // 7')
            if [[ $retention_days -gt 30 ]]; then
                warnings+=("Long retention period ($retention_days days) in development environment")
            fi
            ;;
    esac
    
    # Print warnings
    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo "Configuration warnings:"
        printf "  - %s\n" "${warnings[@]}"
    fi
    
    # Print errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "Business rule validation errors:"
        printf "  - %s\n" "${errors[@]}"
        return 1
    fi
    
    return 0
}

# Generate configuration template
generate_config_template() {
    local environment="${1:-development}"
    local output_file="${2:-k8s-config-template.yaml}"
    
    cat > "$output_file" << EOF
# Kubernetes Maintenance Tool Configuration
# Environment: $environment
# Generated: $(date)

environment: $environment

cluster:
  name: "my-cluster"
  context: "default"
  region: "us-west-2"

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

backup:
  enabled: true
  retention_count: 5
  storage_path: "/var/backups/k8s-maintenance"

alerts:
  enabled: false
  webhook_url: ""
  channels: []

timeouts:
  kubectl_timeout: 30
  drain_timeout: 300
  health_check_timeout: 60
EOF

    log_info "Generated configuration template: $output_file"
}

# Configuration drift detection
detect_config_drift() {
    local current_config="$1"
    local baseline_config="${2:-k8s-config-baseline.yaml}"
    
    if [[ ! -f "$baseline_config" ]]; then
        log_warn "No baseline configuration found: $baseline_config"
        return 0
    fi
    
    log_info "Detecting configuration drift against baseline"
    
    local current_json baseline_json
    current_json=$(yq eval -o=json "$current_config" 2>/dev/null)
    baseline_json=$(yq eval -o=json "$baseline_config" 2>/dev/null)
    
    if [[ -z "$current_json" || -z "$baseline_json" ]]; then
        log_error "Failed to parse configuration files for drift detection"
        return 1
    fi
    
    # Compare configurations
    local diff_output
    diff_output=$(diff <(echo "$baseline_json" | jq -S .) <(echo "$current_json" | jq -S .) 2>/dev/null)
    
    if [[ -n "$diff_output" ]]; then
        log_warn "Configuration drift detected:"
        echo "$diff_output"
        return 1
    else
        log_info "No configuration drift detected"
        return 0
    fi
}

# Create baseline configuration
create_baseline_config() {
    local current_config="$1"
    local baseline_config="${2:-k8s-config-baseline.yaml}"
    
    if validate_config "$current_config"; then
        cp "$current_config" "$baseline_config"
        log_info "Created baseline configuration: $baseline_config"
    else
        log_error "Cannot create baseline from invalid configuration"
        return 1
    fi
}