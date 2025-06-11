#!/bin/bash

#==============================================================================
# Error Handling Framework
# Provides consistent error handling, rollback mechanisms, circuit breakers,
# and retry logic across all modules
#==============================================================================

# Error handling configuration
declare -g ERROR_HANDLER_INITIALIZED=false
declare -g ROLLBACK_STACK=()
declare -g CIRCUIT_BREAKER_STATE=()
declare -g RETRY_ATTEMPTS=3
declare -g RETRY_DELAY=2
declare -g MAX_CIRCUIT_FAILURES=5
declare -g CIRCUIT_RESET_TIMEOUT=300

# Error codes
readonly E_SUCCESS=0
readonly E_GENERAL_ERROR=1
readonly E_CONFIG_ERROR=2
readonly E_NETWORK_ERROR=3
readonly E_AUTH_ERROR=4
readonly E_KUBECTL_ERROR=5
readonly E_TIMEOUT_ERROR=6
readonly E_VALIDATION_ERROR=7
readonly E_PERMISSION_ERROR=8
readonly E_RESOURCE_NOT_FOUND=9
readonly E_CIRCUIT_BREAKER_OPEN=10

# Initialize error handling system
init_error_handling() {
    if [[ "$ERROR_HANDLER_INITIALIZED" == "true" ]]; then
        return 0
    fi
    
    # Set up global error handling
    set -eE  # Exit on error and inherit ERR trap
    
    # Trap errors, interrupts, and exit
    trap 'handle_error $? $LINENO' ERR
    trap 'handle_interrupt' INT TERM
    trap 'handle_exit' EXIT
    
    # Initialize circuit breaker states
    init_circuit_breakers
    
    ERROR_HANDLER_INITIALIZED=true
    log_debug "Error handling system initialized"
}

# Global error handler
handle_error() {
    local exit_code=$1
    local line_number=$2
    local command="${BASH_COMMAND}"
    local function_name="${FUNCNAME[2]:-main}"
    
    log_error "Error in function '$function_name' at line $line_number: $command (exit code: $exit_code)"
    
    # Execute rollback operations
    execute_rollback_stack
    
    # Clean up temporary resources
    cleanup_on_error
    
    # Don't exit if we're in a retry context
    if [[ "${RETRY_CONTEXT:-false}" == "true" ]]; then
        return $exit_code
    fi
    
    exit $exit_code
}

# Handle interrupts (Ctrl+C, etc.)
handle_interrupt() {
    log_warn "Operation interrupted by user"
    
    # Execute rollback operations
    execute_rollback_stack
    
    # Clean up temporary resources
    cleanup_on_error
    
    exit 130  # Standard exit code for SIGINT
}

# Handle script exit
handle_exit() {
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_debug "Script completed successfully"
    else
        log_error "Script exited with error code: $exit_code"
    fi
    
    # Always cleanup, but don't rollback on successful exit
    cleanup_temp_resources
    cleanup_secrets
}

# Retry mechanism with exponential backoff
retry_with_backoff() {
    local max_attempts="${1:-$RETRY_ATTEMPTS}"
    local delay="${2:-$RETRY_DELAY}"
    local max_delay="${3:-60}"
    local operation_name="${4:-operation}"
    shift 4
    local command=("$@")
    
    local attempt=1
    local current_delay=$delay
    
    log_info "Starting $operation_name with retry (max attempts: $max_attempts)"
    
    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Attempt $attempt of $max_attempts for $operation_name"
        
        # Set retry context to prevent global error handler from exiting
        RETRY_CONTEXT=true
        
        # Execute command and capture result
        if "${command[@]}"; then
            log_info "$operation_name succeeded on attempt $attempt"
            RETRY_CONTEXT=false
            return 0
        fi
        
        local exit_code=$?
        RETRY_CONTEXT=false
        
        # Check if this is a permanent failure (no retry)
        if is_permanent_failure $exit_code; then
            log_error "$operation_name failed permanently (exit code: $exit_code)"
            return $exit_code
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "$operation_name failed on attempt $attempt, retrying in ${current_delay}s..."
            sleep $current_delay
            
            # Exponential backoff with jitter
            current_delay=$((current_delay * 2))
            if [[ $current_delay -gt $max_delay ]]; then
                current_delay=$max_delay
            fi
            
            # Add jitter (±25%)
            local jitter=$((current_delay / 4))
            current_delay=$((current_delay + (RANDOM % (jitter * 2)) - jitter))
        fi
        
        ((attempt++))
    done
    
    log_error "$operation_name failed after $max_attempts attempts"
    return $exit_code
}

# Check if error code represents a permanent failure
is_permanent_failure() {
    local exit_code=$1
    
    case $exit_code in
        $E_AUTH_ERROR|\
        $E_PERMISSION_ERROR|\
        $E_VALIDATION_ERROR|\
        $E_CONFIG_ERROR)
            return 0  # Permanent failure
            ;;
        *)
            return 1  # Temporary failure, can retry
            ;;
    esac
}

# Circuit breaker implementation
init_circuit_breakers() {
    # Initialize circuit breaker states for different services
    CIRCUIT_BREAKER_STATE["kubectl"]="closed:0:0"
    CIRCUIT_BREAKER_STATE["api_server"]="closed:0:0"
    CIRCUIT_BREAKER_STATE["metrics_server"]="closed:0:0"
    CIRCUIT_BREAKER_STATE["storage"]="closed:0:0"
}

# Check circuit breaker state
check_circuit_breaker() {
    local service="$1"
    local current_time=$(date +%s)
    
    if [[ -z "${CIRCUIT_BREAKER_STATE[$service]:-}" ]]; then
        CIRCUIT_BREAKER_STATE["$service"]="closed:0:0"
    fi
    
    local state_info="${CIRCUIT_BREAKER_STATE[$service]}"
    local state=$(echo "$state_info" | cut -d: -f1)
    local failure_count=$(echo "$state_info" | cut -d: -f2)
    local last_failure_time=$(echo "$state_info" | cut -d: -f3)
    
    case "$state" in
        "open")
            # Check if we should try to close the circuit
            if [[ $((current_time - last_failure_time)) -gt $CIRCUIT_RESET_TIMEOUT ]]; then
                CIRCUIT_BREAKER_STATE["$service"]="half-open:$failure_count:$last_failure_time"
                log_info "Circuit breaker for $service moved to half-open state"
                return 0
            else
                log_warn "Circuit breaker for $service is open (cooling down)"
                return $E_CIRCUIT_BREAKER_OPEN
            fi
            ;;
        "half-open")
            # Allow one attempt
            return 0
            ;;
        "closed")
            # Normal operation
            return 0
            ;;
    esac
}

# Record circuit breaker result
record_circuit_breaker_result() {
    local service="$1"
    local success="$2"  # true/false
    local current_time=$(date +%s)
    
    if [[ -z "${CIRCUIT_BREAKER_STATE[$service]:-}" ]]; then
        CIRCUIT_BREAKER_STATE["$service"]="closed:0:0"
    fi
    
    local state_info="${CIRCUIT_BREAKER_STATE[$service]}"
    local state=$(echo "$state_info" | cut -d: -f1)
    local failure_count=$(echo "$state_info" | cut -d: -f2)
    
    if [[ "$success" == "true" ]]; then
        # Success - reset or close circuit
        CIRCUIT_BREAKER_STATE["$service"]="closed:0:0"
        if [[ "$state" != "closed" ]]; then
            log_info "Circuit breaker for $service closed after successful operation"
        fi
    else
        # Failure - increment count and potentially open circuit
        ((failure_count++))
        
        if [[ $failure_count -ge $MAX_CIRCUIT_FAILURES ]]; then
            CIRCUIT_BREAKER_STATE["$service"]="open:$failure_count:$current_time"
            log_error "Circuit breaker for $service opened after $failure_count failures"
        else
            CIRCUIT_BREAKER_STATE["$service"]="$state:$failure_count:$current_time"
            log_warn "Circuit breaker for $service recorded failure $failure_count/$MAX_CIRCUIT_FAILURES"
        fi
    fi
}

# Execute command with circuit breaker protection
execute_with_circuit_breaker() {
    local service="$1"
    shift
    local command=("$@")
    
    # Check circuit breaker state
    if ! check_circuit_breaker "$service"; then
        return $E_CIRCUIT_BREAKER_OPEN
    fi
    
    # Execute command
    local exit_code=0
    if "${command[@]}"; then
        record_circuit_breaker_result "$service" "true"
    else
        exit_code=$?
        record_circuit_breaker_result "$service" "false"
    fi
    
    return $exit_code
}

# Safe kubectl execution with retry and circuit breaker
safe_kubectl() {
    local operation="$1"
    shift
    local kubectl_args=("$@")
    
    execute_with_circuit_breaker "kubectl" \
        retry_with_backoff 3 2 30 "kubectl $operation" \
        kubectl "${kubectl_args[@]}"
}

# Rollback mechanism
add_rollback_operation() {
    local operation="$1"
    local description="${2:-Rollback operation}"
    
    ROLLBACK_STACK+=("$operation|$description")
    log_debug "Added rollback operation: $description"
}

# Execute all rollback operations in reverse order
execute_rollback_stack() {
    if [[ ${#ROLLBACK_STACK[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_warn "Executing rollback operations..."
    
    # Execute in reverse order (LIFO)
    for ((i=${#ROLLBACK_STACK[@]}-1; i>=0; i--)); do
        local rollback_entry="${ROLLBACK_STACK[i]}"
        local operation=$(echo "$rollback_entry" | cut -d'|' -f1)
        local description=$(echo "$rollback_entry" | cut -d'|' -f2)
        
        log_info "Rollback: $description"
        
        # Execute rollback operation, but don't fail if it errors
        if ! eval "$operation" 2>/dev/null; then
            log_warn "Rollback operation failed: $description"
        fi
    done
    
    # Clear rollback stack
    ROLLBACK_STACK=()
    log_info "Rollback operations completed"
}

# Clear rollback stack (call after successful operation)
clear_rollback_stack() {
    ROLLBACK_STACK=()
    log_debug "Rollback stack cleared"
}

# Error-safe function wrapper
safe_execute() {
    local function_name="$1"
    local error_message="${2:-Operation failed}"
    shift 2
    local args=("$@")
    
    log_debug "Executing safe operation: $function_name"
    
    if "$function_name" "${args[@]}"; then
        log_debug "Safe operation completed: $function_name"
        return 0
    else
        local exit_code=$?
        log_error "$error_message (exit code: $exit_code)"
        return $exit_code
    fi
}

# Timeout wrapper for operations
timeout_execute() {
    local timeout_seconds="$1"
    local operation_name="$2"
    shift 2
    local command=("$@")
    
    log_debug "Executing with timeout (${timeout_seconds}s): $operation_name"
    
    if timeout "$timeout_seconds" "${command[@]}"; then
        log_debug "Operation completed within timeout: $operation_name"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Operation timed out after ${timeout_seconds}s: $operation_name"
            return $E_TIMEOUT_ERROR
        else
            log_error "Operation failed: $operation_name (exit code: $exit_code)"
            return $exit_code
        fi
    fi
}

# Cleanup on error
cleanup_on_error() {
    log_info "Performing error cleanup..."
    
    # Clean up temporary files
    cleanup_temp_resources
    
    # Reset any partial state changes
    reset_partial_changes
    
    # Close any open connections
    cleanup_connections
}

# Clean up temporary resources
cleanup_temp_resources() {
    # Clean up temp directories
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_debug "Cleaned up temp directory: $TEMP_DIR"
    fi
    
    # Clean up any PID files
    for pid_file in /tmp/k8s-maintenance-*.pid; do
        if [[ -f "$pid_file" ]]; then
            rm -f "$pid_file"
        fi
    done
}

# Reset partial changes
reset_partial_changes() {
    # This would contain logic to undo partial operations
    # Implementation depends on specific operations being performed
    log_debug "Resetting partial changes"
}

# Cleanup connections
cleanup_connections() {
    # Close any port forwards
    pkill -f "kubectl.*port-forward" 2>/dev/null || true
    
    # Clean up any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    
    log_debug "Cleaned up connections and background processes"
}

# Validate error handling setup
validate_error_handling() {
    local issues=()
    
    if [[ "$ERROR_HANDLER_INITIALIZED" != "true" ]]; then
        issues+=("Error handling not initialized")
    fi
    
    if ! command -v timeout >/dev/null 2>&1; then
        issues+=("timeout command not available")
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        log_error "Error handling validation failed:"
        printf "  - %s\n" "${issues[@]}"
        return 1
    fi
    
    log_debug "Error handling validation passed"
    return 0
}

# Show circuit breaker status
show_circuit_breaker_status() {
    echo "Circuit Breaker Status:"
    echo "======================"
    
    for service in "${!CIRCUIT_BREAKER_STATE[@]}"; do
        local state_info="${CIRCUIT_BREAKER_STATE[$service]}"
        local state=$(echo "$state_info" | cut -d: -f1)
        local failure_count=$(echo "$state_info" | cut -d: -f2)
        local last_failure_time=$(echo "$state_info" | cut -d: -f3)
        
        echo "Service: $service"
        echo "  State: $state"
        echo "  Failures: $failure_count"
        
        if [[ $last_failure_time -gt 0 ]]; then
            local last_failure_date=$(date -d "@$last_failure_time" 2>/dev/null || echo "Unknown")
            echo "  Last Failure: $last_failure_date"
        fi
        echo
    done
}