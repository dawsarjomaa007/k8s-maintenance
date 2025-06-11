#!/bin/bash

#==============================================================================
# Secrets Management for Kubernetes Maintenance Tool
# Handles secure loading and management of sensitive configuration data
#==============================================================================

SECRETS_DIR="${SCRIPT_DIR}/secrets"
SECRETS_FILE="${SECRETS_DIR}/secrets.env"
VAULT_FILE="${SECRETS_DIR}/vault.json"

# Initialize secrets management
init_secrets() {
    # Create secrets directory if it doesn't exist
    if [[ ! -d "$SECRETS_DIR" ]]; then
        mkdir -p "$SECRETS_DIR"
        chmod 700 "$SECRETS_DIR"
        log_info "Created secrets directory: $SECRETS_DIR"
    fi
    
    # Create default secrets template if not exists
    if [[ ! -f "$SECRETS_FILE" ]]; then
        create_secrets_template
    fi
}

# Create secrets template
create_secrets_template() {
    cat > "$SECRETS_FILE" << 'EOF'
# Kubernetes Maintenance Tool Secrets
# Store sensitive configuration values here
# This file should never be committed to version control

# Slack webhook for alerts
SLACK_WEBHOOK_URL=""

# Kubernetes service account tokens
K8S_SERVICE_ACCOUNT_TOKEN=""

# Database credentials (if using external storage)
DB_PASSWORD=""
DB_CONNECTION_STRING=""

# External monitoring system API keys
PROMETHEUS_API_KEY=""
GRAFANA_API_KEY=""

# Backup storage credentials
BACKUP_ACCESS_KEY=""
BACKUP_SECRET_KEY=""

# Certificate paths
TLS_CERT_PATH=""
TLS_KEY_PATH=""
CA_CERT_PATH=""
EOF
    
    chmod 600 "$SECRETS_FILE"
    log_info "Created secrets template: $SECRETS_FILE"
    log_warn "Please update secrets file with actual values"
}

# Load secrets from file
load_secrets() {
    if [[ -f "$SECRETS_FILE" ]]; then
        # Source the secrets file in a subshell to avoid polluting current environment
        set -a  # Automatically export variables
        source "$SECRETS_FILE"
        set +a  # Stop auto-export
        log_debug "Loaded secrets from $SECRETS_FILE"
    else
        log_warn "Secrets file not found: $SECRETS_FILE"
    fi
}

# Validate secrets format
validate_secrets() {
    local errors=()
    
    if [[ ! -f "$SECRETS_FILE" ]]; then
        echo "ERROR: Secrets file not found: $SECRETS_FILE"
        return 1
    fi
    
    # Check file permissions
    local perms
    perms=$(stat -c "%a" "$SECRETS_FILE" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        errors+=("Secrets file has incorrect permissions: $perms (should be 600)")
    fi
    
    # Validate that no secrets are committed (basic check)
    if [[ -f "${SCRIPT_DIR}/.git/config" ]]; then
        if git check-ignore "$SECRETS_FILE" >/dev/null 2>&1; then
            log_debug "Secrets file is properly ignored by git"
        else
            errors+=("WARNING: Secrets file may not be ignored by git")
        fi
    fi
    
    # Check for empty required secrets in production
    local environment
    environment=$(get_config "environment")
    if [[ "$environment" == "production" ]]; then
        local required_secrets=("SLACK_WEBHOOK_URL")
        for secret in "${required_secrets[@]}"; do
            if [[ -z "${!secret}" ]]; then
                errors+=("Required secret '$secret' is empty in production environment")
            fi
        done
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "Secrets validation errors:"
        printf "  - %s\n" "${errors[@]}"
        return 1
    fi
    
    return 0
}

# Encrypt secrets (basic implementation)
encrypt_secrets() {
    local password="$1"
    
    if [[ -z "$password" ]]; then
        echo "ERROR: Password required for encryption"
        return 1
    fi
    
    if [[ ! -f "$SECRETS_FILE" ]]; then
        echo "ERROR: Secrets file not found: $SECRETS_FILE"
        return 1
    fi
    
    # Encrypt using openssl
    openssl enc -aes-256-cbc -salt -in "$SECRETS_FILE" -out "${SECRETS_FILE}.enc" -k "$password"
    
    if [[ $? -eq 0 ]]; then
        log_info "Secrets encrypted to ${SECRETS_FILE}.enc"
        log_warn "Original secrets file still exists. Remove manually if needed."
    else
        log_error "Failed to encrypt secrets"
        return 1
    fi
}

# Decrypt secrets (basic implementation)
decrypt_secrets() {
    local password="$1"
    
    if [[ -z "$password" ]]; then
        echo "ERROR: Password required for decryption"
        return 1
    fi
    
    if [[ ! -f "${SECRETS_FILE}.enc" ]]; then
        echo "ERROR: Encrypted secrets file not found: ${SECRETS_FILE}.enc"
        return 1
    fi
    
    # Decrypt using openssl
    openssl enc -d -aes-256-cbc -in "${SECRETS_FILE}.enc" -out "$SECRETS_FILE" -k "$password"
    
    if [[ $? -eq 0 ]]; then
        chmod 600 "$SECRETS_FILE"
        log_info "Secrets decrypted to $SECRETS_FILE"
    else
        log_error "Failed to decrypt secrets"
        return 1
    fi
}

# Get secret value
get_secret() {
    local key="$1"
    
    if [[ -z "$key" ]]; then
        echo "ERROR: Secret key required"
        return 1
    fi
    
    # Load secrets if not already loaded
    load_secrets
    
    # Return the value of the secret
    echo "${!key}"
}

# Set secret value
set_secret() {
    local key="$1"
    local value="$2"
    
    if [[ -z "$key" || -z "$value" ]]; then
        echo "ERROR: Both key and value required"
        return 1
    fi
    
    # Create backup
    if [[ -f "$SECRETS_FILE" ]]; then
        cp "$SECRETS_FILE" "${SECRETS_FILE}.bak"
    fi
    
    # Update or add the secret
    if grep -q "^${key}=" "$SECRETS_FILE" 2>/dev/null; then
        # Update existing
        sed -i "s/^${key}=.*/${key}=\"${value}\"/" "$SECRETS_FILE"
    else
        # Add new
        echo "${key}=\"${value}\"" >> "$SECRETS_FILE"
    fi
    
    log_info "Updated secret: $key"
}

# Rotate secrets (placeholder for integration with external secret management)
rotate_secrets() {
    log_info "Starting secrets rotation..."
    
    # This would integrate with external systems like:
    # - HashiCorp Vault
    # - AWS Secrets Manager
    # - Azure Key Vault
    # - Kubernetes Secrets
    
    log_warn "Secrets rotation not implemented. Integrate with your secret management system."
}

# Clean up secrets from memory
cleanup_secrets() {
    # Unset sensitive environment variables
    local secret_vars=("SLACK_WEBHOOK_URL" "K8S_SERVICE_ACCOUNT_TOKEN" "DB_PASSWORD" 
                      "DB_CONNECTION_STRING" "PROMETHEUS_API_KEY" "GRAFANA_API_KEY"
                      "BACKUP_ACCESS_KEY" "BACKUP_SECRET_KEY")
    
    for var in "${secret_vars[@]}"; do
        unset "$var"
    done
    
    log_debug "Cleaned up secrets from memory"
}