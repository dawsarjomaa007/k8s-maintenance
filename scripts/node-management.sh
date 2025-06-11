#!/bin/bash

#==============================================================================
# Enhanced Node Management Module
# Functions for safe node maintenance operations with comprehensive error handling
#==============================================================================

# Source error handling framework if not already loaded
if [[ "$ERROR_HANDLER_INITIALIZED" != "true" ]]; then
    source "${SCRIPT_DIR}/scripts/error-handler.sh"
fi

# Enhanced node drain with rollback and circuit breaker protection
drain_node() {
    local node="$1"
    local force="${2:-false}"
    
    if [[ -z "$node" ]]; then
        log_error "Node name is required"
        return $E_VALIDATION_ERROR
    fi
    
    # Validate node name format
    if ! validate_resource_name "$node" "node"; then
        return $E_VALIDATION_ERROR
    fi
    
    # Check if node exists with retry and circuit breaker
    log_info "Verifying node exists: $node"
    if ! execute_with_circuit_breaker "kubectl" \
         retry_with_backoff 3 2 10 "node existence check" \
         kubectl get node "$node"; then
        log_error "Node '$node' not found or inaccessible"
        return $E_RESOURCE_NOT_FOUND
    fi
    
    # Check if node is already cordoned
    local node_status
    if node_status=$(safe_kubectl get "node info" get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null); then
        if [[ "$node_status" == "true" ]]; then
            log_warn "Node '$node' is already cordoned"
        fi
    fi
    
    # Show current pods on the node with timeout
    log_info "Retrieving current pods on node $node"
    echo -e "\n${CYAN}=== Pods currently running on node $node ===${NC}"
    
    if ! timeout_execute 30 "pod listing" \
         kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName="$node" --no-headers; then
        log_error "Failed to retrieve pod list for node $node"
        return $E_KUBECTL_ERROR
    fi
    
    # Confirmation prompt unless force is specified
    if [[ "$force" != "true" && "${FORCE_OPERATIONS:-false}" != "true" ]]; then
        if ! confirm_critical_action "Are you sure you want to drain node '$node'? This will evict all pods." "yes"; then
            log_info "Node drain cancelled by user"
            return $E_SUCCESS
        fi
    fi
    
    log_info "Starting drain operation for node '$node'..."
    
    # Add rollback operation to uncordon the node if drain fails
    add_rollback_operation "kubectl uncordon '$node' 2>/dev/null || true" "Uncordon node $node"
    
    # Cordon the node first with retry
    log_info "Cordoning node '$node'..."
    if ! execute_with_circuit_breaker "kubectl" \
         retry_with_backoff 3 2 10 "node cordon" \
         kubectl cordon "$node"; then
        log_error "Failed to cordon node '$node'"
        return $E_KUBECTL_ERROR
    fi
    
    # Get drain configuration with defaults
    local drain_timeout
    local grace_period
    local ignore_daemonsets
    
    drain_timeout=$(get_config "timeouts.drain_timeout" "300")
    grace_period=$(get_config "node_maintenance.grace_period" "30")
    ignore_daemonsets=$(get_config "node_maintenance.ignore_daemonsets" "true")
    
    log_debug "Drain configuration: timeout=${drain_timeout}s, grace_period=${grace_period}s, ignore_daemonsets=$ignore_daemonsets"
    
    # Build drain command with proper error handling
    local drain_args=(
        "drain" "$node"
        "--delete-emptydir-data"
        "--timeout=${drain_timeout}s"
        "--grace-period=${grace_period}"
        "--force"
    )
    
    if [[ "$ignore_daemonsets" == "true" ]]; then
        drain_args+=("--ignore-daemonsets")
    fi
    
    # Execute drain with timeout and retry
    log_info "Draining node '$node' (timeout: ${drain_timeout}s)..."
    if execute_with_circuit_breaker "kubectl" \
       timeout_execute $((drain_timeout + 30)) "node drain" \
       kubectl "${drain_args[@]}"; then
        log_info "Node '$node' successfully drained"
        
        # Verify drain completed successfully
        if verify_node_drained "$node"; then
            clear_rollback_stack  # Don't uncordon on success
            return $E_SUCCESS
        else
            log_error "Node drain verification failed"
            return $E_GENERAL_ERROR
        fi
    else
        local exit_code=$?
        log_error "Failed to drain node '$node' (exit code: $exit_code)"
        return $exit_code
    fi
}

# Verify that a node has been properly drained
verify_node_drained() {
    local node="$1"
    
    log_info "Verifying node '$node' drain completion..."
    
    # Check if any non-daemonset pods remain
    local remaining_pods
    if remaining_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" \
                       -o json 2>/dev/null | jq -r '.items[] | select(.metadata.ownerReferences[]?.kind != "DaemonSet") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null); then
        
        if [[ -n "$remaining_pods" ]]; then
            log_warn "Non-daemonset pods still running on node '$node':"
            echo "$remaining_pods"
            return 1
        else
            log_info "Node '$node' successfully drained - no non-daemonset pods remaining"
            return 0
        fi
    else
        log_warn "Could not verify drain status for node '$node'"
        return 1
    fi
}

# Enhanced cordon/uncordon with rollback support
cordon_node() {
    local node="$1"
    local action="${2:-cordon}"
    local force="${3:-false}"
    
    if [[ -z "$node" ]]; then
        log_error "Node name is required"
        return $E_VALIDATION_ERROR
    fi
    
    if [[ "$action" != "cordon" && "$action" != "uncordon" ]]; then
        log_error "Action must be 'cordon' or 'uncordon'"
        return $E_VALIDATION_ERROR
    fi
    
    # Validate node name
    if ! validate_resource_name "$node" "node"; then
        return $E_VALIDATION_ERROR
    fi
    
    # Check if node exists
    if ! execute_with_circuit_breaker "kubectl" \
         retry_with_backoff 2 1 5 "node existence check" \
         kubectl get node "$node"; then
        log_error "Node '$node' not found or inaccessible"
        return $E_RESOURCE_NOT_FOUND
    fi
    
    # Check current cordon status
    local current_status
    if current_status=$(safe_kubectl get "node status" get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null); then
        if [[ "$action" == "cordon" && "$current_status" == "true" ]]; then
            log_info "Node '$node' is already cordoned"
            return $E_SUCCESS
        elif [[ "$action" == "uncordon" && "$current_status" != "true" ]]; then
            log_info "Node '$node' is already uncordoned"
            return $E_SUCCESS
        fi
    fi
    
    # Confirmation for cordon operations
    if [[ "$force" != "true" && "${FORCE_OPERATIONS:-false}" != "true" ]]; then
        if ! confirm_action "Are you sure you want to $action node '$node'?"; then
            log_info "Node $action cancelled by user"
            return $E_SUCCESS
        fi
    fi
    
    # Add rollback operation for cordon (opposite action)
    if [[ "$action" == "cordon" ]]; then
        add_rollback_operation "kubectl uncordon '$node' 2>/dev/null || true" "Uncordon node $node if cordon fails"
    fi
    
    log_info "${action^}ing node '$node'..."
    if execute_with_circuit_breaker "kubectl" \
       retry_with_backoff 3 2 10 "node $action" \
       kubectl "$action" "$node"; then
        log_info "Node '$node' successfully ${action}ed"
        
        # Clear rollback for successful cordon (we want to keep it cordoned)
        if [[ "$action" == "cordon" ]]; then
            clear_rollback_stack
        fi
        
        return $E_SUCCESS
    else
        log_error "Failed to $action node '$node'"
        return $E_KUBECTL_ERROR
    fi
}

# Enhanced pending pods check with detailed analysis
check_pending_pods() {
    log_info "Checking for pending pods..."
    
    local pending_pods_json
    if ! pending_pods_json=$(execute_with_circuit_breaker "kubectl" \
                            timeout_execute 30 "pending pods query" \
                            kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o json); then
        log_error "Failed to retrieve pending pods"
        return $E_KUBECTL_ERROR
    fi
    
    local pending_count
    pending_count=$(echo "$pending_pods_json" | jq '.items | length' 2>/dev/null || echo "0")
    
    if [[ "$pending_count" -eq 0 ]]; then
        echo -e "${GREEN}✓ No pending pods found${NC}"
        return $E_SUCCESS
    fi
    
    log_warn "Found $pending_count pending pods"
    echo -e "\n${YELLOW}=== Pending Pods Analysis ===${NC}"
    
    # Show detailed pending pod information
    if ! echo "$pending_pods_json" | jq -r '.items[] | 
        "\(.metadata.namespace)/\(.metadata.name): 
         Status: \(.status.phase // "Unknown")
         Reason: \(.status.conditions[-1].reason // "Unknown") 
         Message: \(.status.conditions[-1].message // "No message")
         Node: \(.spec.nodeName // "Unassigned")
         Created: \(.metadata.creationTimestamp)
         ---"' 2>/dev/null; then
        log_error "Failed to parse pending pods details"
        return $E_GENERAL_ERROR
    fi
    
    return $E_SUCCESS
}

# Show node capacity and allocatable resources
show_node_capacity() {
    local node="$1"
    
    if [[ -z "$node" ]]; then
        echo -e "\n${CYAN}=== All Nodes Capacity ===${NC}"
        kubectl describe nodes | grep -A 5 "Capacity:\|Allocatable:"
    else
        echo -e "\n${CYAN}=== Node $node Capacity ===${NC}"
        kubectl describe node "$node" | grep -A 5 "Capacity:\|Allocatable:"
    fi
}

# List node conditions and taints
show_node_details() {
    local node="$1"
    
    if [[ -z "$node" ]]; then
        log "ERROR" "Node name is required"
        return 1
    fi
    
    echo -e "\n${CYAN}=== Node $node Details ===${NC}"
    
    # Node conditions
    echo -e "\n${YELLOW}Node Conditions:${NC}"
    kubectl get node "$node" -o json | jq -r '.status.conditions[] | "\(.type): \(.status) - \(.message // "N/A")"'
    
    # Node taints
    echo -e "\n${YELLOW}Node Taints:${NC}"
    local taints=$(kubectl get node "$node" -o json | jq -r '.spec.taints[]? | "\(.key)=\(.value):\(.effect)"')
    if [[ -n "$taints" ]]; then
        echo "$taints"
    else
        echo "No taints"
    fi
    
    # Node labels
    echo -e "\n${YELLOW}Node Labels:${NC}"
    kubectl get node "$node" --show-labels --no-headers | awk '{print $6}' | tr ',' '\n' | head -10
}

# Enhanced node resource monitoring with error handling
monitor_node_resources() {
    local node="$1"
    local duration="${2:-60}"
    local interval="${3:-5}"
    
    if [[ -z "$node" ]]; then
        log_error "Node name is required"
        return $E_VALIDATION_ERROR
    fi
    
    # Validate parameters
    if [[ ! "$duration" =~ ^[0-9]+$ ]] || [[ ! "$interval" =~ ^[0-9]+$ ]]; then
        log_error "Duration and interval must be positive integers"
        return $E_VALIDATION_ERROR
    fi
    
    if [[ $duration -lt $interval ]]; then
        log_error "Duration must be greater than interval"
        return $E_VALIDATION_ERROR
    fi
    
    # Check if metrics server is available
    if ! execute_with_circuit_breaker "metrics_server" \
         retry_with_backoff 2 2 10 "metrics server check" \
         kubectl top node "$node" --no-headers; then
        log_error "Metrics server not available or node '$node' not found"
        return $E_NETWORK_ERROR
    fi
    
    log_info "Monitoring node '$node' for $duration seconds (interval: ${interval}s)"
    
    local end_time=$(($(date +%s) + duration))
    local error_count=0
    local max_errors=5
    
    echo -e "\n${CYAN}=== Node Resource Monitoring ===${NC}"
    printf "%-8s %-15s %-15s %-15s %-10s\n" "Time" "CPU%" "Memory%" "Pods" "Status"
    printf "%-8s %-15s %-15s %-15s %-10s\n" "--------" "-------" "--------" "----" "------"
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local timestamp=$(date +%H:%M:%S)
        local cpu_percent="N/A"
        local memory_percent="N/A"
        local pod_count="N/A"
        local status="ERROR"
        
        # Get metrics with error handling
        if metrics=$(execute_with_circuit_breaker "metrics_server" \
                    timeout_execute 10 "node metrics" \
                    kubectl top node "$node" --no-headers 2>/dev/null); then
            cpu_percent=$(echo "$metrics" | awk '{print $3}' 2>/dev/null || echo "N/A")
            memory_percent=$(echo "$metrics" | awk '{print $5}' 2>/dev/null || echo "N/A")
            status="OK"
            error_count=0
        else
            ((error_count++))
            if [[ $error_count -ge $max_errors ]]; then
                log_error "Too many monitoring errors, stopping"
                return $E_NETWORK_ERROR
            fi
        fi
        
        # Get pod count with error handling
        if pod_count_result=$(timeout_execute 10 "pod count" \
                             kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" --no-headers 2>/dev/null | wc -l); then
            pod_count="$pod_count_result"
        fi
        
        printf "%-8s %-15s %-15s %-15s %-10s\n" "$timestamp" "$cpu_percent" "$memory_percent" "$pod_count" "$status"
        
        sleep "$interval"
    done
    
    log_info "Node monitoring completed for '$node'"
    return $E_SUCCESS
}

# Evacuate all user pods from a node (excluding system pods)
evacuate_user_pods() {
    local node="$1"
    local force="${2:-false}"
    
    if [[ -z "$node" ]]; then
        log "ERROR" "Node name is required"
        return 1
    fi
    
    # Get user pods (excluding system namespaces)
    local excluded_namespaces
    excluded_namespaces=$(get_config 'excluded_namespaces' | jq -r '.[]' | tr '\n' '|')
    excluded_namespaces=${excluded_namespaces%|}  # Remove trailing |
    
    local user_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" --no-headers | \
        grep -vE "($excluded_namespaces)" | awk '{print $1 "/" $2}')
    
    if [[ -z "$user_pods" ]]; then
        log "INFO" "No user pods found on node '$node'"
        return 0
    fi
    
    echo -e "\n${CYAN}=== User Pods on Node $node ===${NC}"
    echo "$user_pods"
    
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Delete these user pods from node '$node'?"; then
            log "INFO" "Pod evacuation cancelled"
            return 0
        fi
    fi
    
    log "INFO" "Evacuating user pods from node '$node'..."
    
    echo "$user_pods" | while IFS='/' read -r namespace pod; do
        log "INFO" "Deleting pod $namespace/$pod"
        kubectl delete pod -n "$namespace" "$pod" --grace-period=30 || \
            log "WARN" "Failed to delete pod $namespace/$pod"
    done
    
    log "INFO" "User pod evacuation completed for node '$node'"
}

# Check node disk usage
check_node_disk_usage() {
    local node="$1"
    
    if [[ -z "$node" ]]; then
        log "ERROR" "Node name is required"
        return 1
    fi
    
    log "INFO" "Checking disk usage for node '$node'"
    
    # Use kubectl debug to check disk usage
    kubectl debug node/"$node" -it --image=alpine -- sh -c "
        chroot /host df -h | grep -E '(Filesystem|/dev/)' | head -10
    " 2>/dev/null || {
        log "WARN" "Unable to check disk usage for node '$node' (debug pod method failed)"
        return 1
    }
}