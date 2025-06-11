#!/bin/bash

#==============================================================================
# Enhanced Utility Functions Module
# Common utilities, logging, and helper functions with error handling integration
#==============================================================================

# Source error handling framework
source "${SCRIPT_DIR}/scripts/error-handler.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Enhanced logging function with error handling integration
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Write to log file with error handling
    if ! echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null; then
        echo "[$timestamp] [ERROR] Failed to write to log file: $LOG_FILE" >&2
    fi
    
    case "$level" in
        "ERROR")   echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
        "WARN")    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "INFO")    echo -e "${GREEN}[INFO]${NC} $message" ;;
        "DEBUG")   
            if [[ "${K8S_MAINTENANCE_DEBUG:-false}" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} $message"
            fi
            ;;
        *)         echo "$message" ;;
    esac
}

# Convenience logging functions
log_error() { log "ERROR" "$@"; }
log_warn() { log "WARN" "$@"; }
log_info() { log "INFO" "$@"; }
log_debug() { log "DEBUG" "$@"; }

# Enhanced prerequisites check with circuit breaker
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    local required_tools=("kubectl" "jq" "yq" "timeout")
    
    # Check required tools
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -ne 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install missing tools and try again"
        return $E_CONFIG_ERROR
    fi
    
    # Check kubectl connectivity with retry and circuit breaker
    if ! execute_with_circuit_breaker "kubectl" \
         retry_with_backoff 3 2 10 "kubectl connectivity check" \
         kubectl cluster-info; then
        log_error "Cannot connect to Kubernetes cluster"
        log_info "Please check your kubeconfig and cluster connectivity"
        return $E_NETWORK_ERROR
    fi
    
    # Validate Kubernetes version compatibility
    local k8s_version
    if ! k8s_version=$(safe_kubectl get "version" --output=json | jq -r '.serverVersion.gitVersion' 2>/dev/null); then
        log_warn "Cannot determine Kubernetes version"
    else
        log_info "Connected to Kubernetes cluster version: $k8s_version"
    fi
    
    log_info "Prerequisites check passed"
    return $E_SUCCESS
}

# Enhanced initialization with error handling
initialize() {
    # Initialize error handling first
    if ! init_error_handling; then
        echo "ERROR: Failed to initialize error handling system" >&2
        exit $E_GENERAL_ERROR
    fi
    
    # Create temp directory with error handling
    if ! mkdir -p "$TEMP_DIR" 2>/dev/null; then
        log_error "Failed to create temp directory: $TEMP_DIR"
        return $E_GENERAL_ERROR
    fi
    
    # Add cleanup rollback operation
    add_rollback_operation "rm -rf '$TEMP_DIR'" "Remove temp directory"
    
    # Create log file if it doesn't exist
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo "WARNING: Cannot create log file: $LOG_FILE" >&2
        LOG_FILE="/tmp/k8s-maintenance-$$.log"
        echo "Using temporary log file: $LOG_FILE" >&2
        touch "$LOG_FILE"
    fi
    
    log_info "=== Kubernetes Maintenance Script Started ==="
    log_info "Script directory: $SCRIPT_DIR"
    log_info "Temp directory: $TEMP_DIR"
    log_info "Log file: $LOG_FILE"
    log_info "Process ID: $$"
    
    # Validate error handling setup
    if ! validate_error_handling; then
        return $E_CONFIG_ERROR
    fi
    
    return $E_SUCCESS
}

# Enhanced cleanup function
cleanup() {
    log_debug "Starting cleanup process..."
    
    # Clean up temp directory
    if [[ -d "$TEMP_DIR" ]]; then
        if rm -rf "$TEMP_DIR" 2>/dev/null; then
            log_debug "Cleaned up temp directory: $TEMP_DIR"
        else
            log_warn "Failed to clean up temp directory: $TEMP_DIR"
        fi
    fi
    
    # Kill any background processes we started
    cleanup_connections
    
    log_debug "Cleanup completed"
}

# Enhanced progress indicator with timeout
show_progress() {
    local message="$1"
    local duration="${2:-3}"
    local interval="${3:-0.5}"
    
    echo -ne "${BLUE}[INFO]${NC} $message"
    
    local count=0
    local max_count=$((duration * 2))  # duration / interval
    
    while [[ $count -lt $max_count ]]; do
        echo -n "."
        sleep "$interval"
        ((count++))
    done
    
    echo " done"
}

# Enhanced confirmation prompt with timeout
confirm_action() {
    local message="$1"
    local default="${2:-N}"
    local timeout_seconds="${3:-30}"
    
    if [[ "$default" == "Y" ]]; then
        echo -e "\n${YELLOW}$message (Y/n) [timeout: ${timeout_seconds}s]${NC}"
    else
        echo -e "\n${YELLOW}$message (y/N) [timeout: ${timeout_seconds}s]${NC}"
    fi
    
    local confirmation
    if read -t "$timeout_seconds" -r confirmation; then
        if [[ "$default" == "Y" ]]; then
            [[ "$confirmation" != "n" && "$confirmation" != "N" ]]
        else
            [[ "$confirmation" == "y" || "$confirmation" == "Y" ]]
        fi
    else
        echo  # New line after timeout
        log_warn "Confirmation timed out after ${timeout_seconds}s, using default: $default"
        [[ "$default" == "Y" ]]
    fi
}

# Safe confirmation for critical operations
confirm_critical_action() {
    local message="$1"
    local required_confirmation="${2:-yes}"
    
    echo -e "\n${RED}CRITICAL OPERATION${NC}"
    echo -e "${YELLOW}$message${NC}"
    echo -e "${YELLOW}Type '$required_confirmation' to confirm:${NC}"
    
    local confirmation
    read -r confirmation
    
    if [[ "$confirmation" == "$required_confirmation" ]]; then
        log_info "Critical operation confirmed by user"
        return 0
    else
        log_info "Critical operation cancelled by user"
        return 1
    fi
}

# Enhanced format bytes function
format_bytes() {
    local bytes="$1"
    
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "Invalid"
        return 1
    fi
    
    local units=("B" "KB" "MB" "GB" "TB" "PB")
    local unit=0
    local size=$bytes
    
    while [[ $size -ge 1024 && $unit -lt 5 ]]; do
        size=$((size / 1024))
        unit=$((unit + 1))
    done
    
    if [[ $unit -eq 0 ]]; then
        echo "${size}${units[$unit]}"
    else
        printf "%.1f%s\n" "$(echo "scale=1; $bytes / (1024^$unit)" | bc 2>/dev/null || echo "$size")" "${units[$unit]}"
    fi
}

# Enhanced namespace exclusion check
is_namespace_excluded() {
    local namespace="$1"
    
    if [[ -z "$namespace" ]]; then
        log_error "Namespace parameter required"
        return 1
    fi
    
    # Get excluded namespaces with error handling
    local excluded_namespaces
    if ! excluded_namespaces=$(get_config_array 'excluded_namespaces' 2>/dev/null); then
        log_warn "Failed to get excluded namespaces from config, using defaults"
        excluded_namespaces="kube-system kube-public kube-node-lease"
    fi
    
    # Check if namespace is in excluded list
    local ns
    while read -r ns; do
        if [[ "$ns" == "$namespace" ]]; then
            return 0  # Namespace is excluded
        fi
    done <<< "$excluded_namespaces"
    
    return 1  # Namespace is not excluded
}

# Validate resource name format
validate_resource_name() {
    local name="$1"
    local resource_type="${2:-resource}"
    
    if [[ -z "$name" ]]; then
        log_error "$resource_type name cannot be empty"
        return $E_VALIDATION_ERROR
    fi
    
    # Kubernetes resource name validation (RFC 1123)
    if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid $resource_type name: $name (must match RFC 1123)"
        return $E_VALIDATION_ERROR
    fi
    
    if [[ ${#name} -gt 63 ]]; then
        log_error "$resource_type name too long: $name (max 63 characters)"
        return $E_VALIDATION_ERROR
    fi
    
    return $E_SUCCESS
}

# Safe JSON parsing with error handling
safe_json_parse() {
    local json_string="$1"
    local jq_filter="${2:-.}"
    
    if [[ -z "$json_string" ]]; then
        log_error "JSON string required for parsing"
        return $E_VALIDATION_ERROR
    fi
    
    local result
    if ! result=$(echo "$json_string" | jq -r "$jq_filter" 2>/dev/null); then
        log_error "Failed to parse JSON with filter: $jq_filter"
        return $E_VALIDATION_ERROR
    fi
    
    echo "$result"
    return $E_SUCCESS
}

# Check if we're running in dry-run mode
is_dry_run() {
    [[ "${DRY_RUN:-false}" == "true" ]] || [[ "${K8S_MAINTENANCE_DRY_RUN:-false}" == "true" ]]
}

# Execute command in dry-run aware mode
execute_if_not_dry_run() {
    local description="$1"
    shift
    local command=("$@")
    
    if is_dry_run; then
        log_info "[DRY RUN] Would execute: $description"
        log_debug "[DRY RUN] Command: ${command[*]}"
        return $E_SUCCESS
    else
        log_info "Executing: $description"
        "${command[@]}"
    fi
}

# Enhanced wait function with timeout and progress
wait_for_condition() {
    local condition_description="$1"
    local check_command="$2"
    local timeout_seconds="${3:-300}"
    local check_interval="${4:-5}"
    
    log_info "Waiting for condition: $condition_description (timeout: ${timeout_seconds}s)"
    
    local elapsed=0
    local last_progress=0
    
    while [[ $elapsed -lt $timeout_seconds ]]; do
        if eval "$check_command" >/dev/null 2>&1; then
            log_info "Condition met: $condition_description"
            return $E_SUCCESS
        fi
        
        # Show progress every 30 seconds
        if [[ $((elapsed - last_progress)) -ge 30 ]]; then
            log_info "Still waiting for: $condition_description (${elapsed}s elapsed)"
            last_progress=$elapsed
        fi
        
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    log_error "Timeout waiting for condition: $condition_description"
    return $E_TIMEOUT_ERROR
}

# Get current timestamp in ISO format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Generate unique identifier
generate_id() {
    local prefix="${1:-id}"
    echo "${prefix}-$(date +%s)-$$-${RANDOM}"
}

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Check available disk space
check_disk_space() {
    local path="${1:-/tmp}"
    local min_space_mb="${2:-100}"
    
    local available_kb
    available_kb=$(df "$path" | awk 'NR==2 {print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt $min_space_mb ]]; then
        log_error "Insufficient disk space at $path: ${available_mb}MB available, ${min_space_mb}MB required"
        return $E_GENERAL_ERROR
    fi
    
    log_debug "Disk space check passed: ${available_mb}MB available at $path"
    return $E_SUCCESS
}