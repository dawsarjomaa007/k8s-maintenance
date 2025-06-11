#!/bin/bash

#==============================================================================
# Node Management Module
# Functions for safe node maintenance operations
#==============================================================================

# Safely drain a node
drain_node() {
    local node="$1"
    local force="${2:-false}"
    
    if [[ -z "$node" ]]; then
        log "ERROR" "Node name is required"
        return 1
    fi
    
    # Check if node exists
    if ! kubectl get node "$node" &> /dev/null; then
        log "ERROR" "Node '$node' not found"
        return 1
    fi
    
    # Show current pods on the node
    echo -e "\n${CYAN}=== Pods currently running on node $node ===${NC}"
    kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName="$node" --no-headers
    
    # Confirmation prompt unless force is specified
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Are you sure you want to drain node '$node'?"; then
            log "INFO" "Node drain cancelled"
            return 0
        fi
    fi
    
    log "INFO" "Draining node '$node'..."
    
    # Cordon the node first
    kubectl cordon "$node" || {
        log "ERROR" "Failed to cordon node '$node'"
        return 1
    }
    
    # Get drain configuration
    local drain_timeout=$(get_config "node_maintenance.drain_timeout")
    local grace_period=$(get_config "node_maintenance.grace_period")
    local ignore_daemonsets=$(get_config "node_maintenance.ignore_daemonsets")
    
    # Build drain command
    local drain_cmd="kubectl drain $node --delete-emptydir-data --timeout=${drain_timeout}s --grace-period=${grace_period}"
    
    if [[ "$ignore_daemonsets" == "true" ]]; then
        drain_cmd="$drain_cmd --ignore-daemonsets"
    fi
    
    # Execute drain
    if eval "$drain_cmd"; then
        log "INFO" "Node '$node' successfully drained"
    else
        log "ERROR" "Failed to drain node '$node'"
        return 1
    fi
}

# Check for pending pods
check_pending_pods() {
    log "INFO" "Checking for pending pods..."
    
    local pending_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers)
    
    if [[ -z "$pending_pods" ]]; then
        echo -e "${GREEN}No pending pods found${NC}"
        return 0
    fi
    
    echo -e "\n${YELLOW}=== Pending Pods ===${NC}"
    echo "$pending_pods"
    
    # Show reasons for pending
    echo -e "\n${CYAN}=== Pending Pod Details ===${NC}"
    kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o json | \
        jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[-1].message // "No message")"'
}

# Cordon/Uncordon nodes with confirmation
cordon_node() {
    local node="$1"
    local action="${2:-cordon}"
    
    if [[ -z "$node" ]]; then
        log "ERROR" "Node name is required"
        return 1
    fi
    
    if [[ "$action" != "cordon" && "$action" != "uncordon" ]]; then
        log "ERROR" "Action must be 'cordon' or 'uncordon'"
        return 1
    fi
    
    # Check if node exists
    if ! kubectl get node "$node" &> /dev/null; then
        log "ERROR" "Node '$node' not found"
        return 1
    fi
    
    if ! confirm_action "Are you sure you want to $action node '$node'?"; then
        log "INFO" "Node $action cancelled"
        return 0
    fi
    
    log "INFO" "${action^}ing node '$node'..."
    kubectl "$action" "$node" || {
        log "ERROR" "Failed to $action node '$node'"
        return 1
    }
    
    log "INFO" "Node '$node' successfully ${action}ed"
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

# Monitor node resource usage over time
monitor_node_resources() {
    local node="$1"
    local duration="${2:-60}"
    local interval="${3:-5}"
    
    if [[ -z "$node" ]]; then
        log "ERROR" "Node name is required"
        return 1
    fi
    
    log "INFO" "Monitoring node '$node' for $duration seconds (interval: ${interval}s)"
    
    local end_time=$(($(date +%s) + duration))
    
    echo -e "\n${CYAN}=== Node Resource Monitoring ===${NC}"
    printf "%-8s %-15s %-15s %-15s\n" "Time" "CPU%" "Memory%" "Pods"
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local timestamp=$(date +%H:%M:%S)
        
        if kubectl top node "$node" &> /dev/null; then
            local metrics=$(kubectl top node "$node" --no-headers)
            local cpu_percent=$(echo "$metrics" | awk '{print $3}')
            local memory_percent=$(echo "$metrics" | awk '{print $5}')
        else
            local cpu_percent="N/A"
            local memory_percent="N/A"
        fi
        
        local pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" --no-headers | wc -l)
        
        printf "%-8s %-15s %-15s %-15s\n" "$timestamp" "$cpu_percent" "$memory_percent" "$pod_count"
        
        sleep "$interval"
    done
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