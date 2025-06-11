#!/bin/bash

#==============================================================================
# Cluster Health Check Module
# Functions for monitoring cluster health and resource utilization
#==============================================================================

# Check node status
check_node_status() {
    log "INFO" "Checking node status..."
    
    local nodes_output="$TEMP_DIR/nodes.json"
    kubectl get nodes -o json > "$nodes_output"
    
    local total_nodes=$(jq '.items | length' "$nodes_output")
    local ready_nodes=$(jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' "$nodes_output")
    local not_ready_nodes=$((total_nodes - ready_nodes))
    
    echo -e "\n${CYAN}=== Node Status ===${NC}"
    echo "Total Nodes: $total_nodes"
    echo -e "Ready Nodes: ${GREEN}$ready_nodes${NC}"
    
    if [[ $not_ready_nodes -gt 0 ]]; then
        echo -e "Not Ready Nodes: ${RED}$not_ready_nodes${NC}"
        log "WARN" "$not_ready_nodes nodes are not ready"
        
        # Show not ready nodes
        kubectl get nodes --no-headers | grep -v " Ready " | while read -r line; do
            echo -e "${RED}  $line${NC}"
        done
    else
        echo -e "Not Ready Nodes: ${GREEN}0${NC}"
    fi
    
    # Node resource usage
    echo -e "\n${CYAN}=== Node Resource Usage ===${NC}"
    kubectl top nodes 2>/dev/null || log "WARN" "Metrics server not available for resource usage"
}

# Check pod distribution
check_pod_distribution() {
    log "INFO" "Checking pod distribution across nodes..."
    
    echo -e "\n${CYAN}=== Pod Distribution ===${NC}"
    
    # Get pod count per node
    kubectl get pods --all-namespaces -o wide --no-headers | \
    awk '{print $8}' | grep -v "<none>" | sort | uniq -c | \
    while read -r count node; do
        echo "Node $node: $count pods"
    done
    
    # Check for pods in problematic states
    local problematic_pods=$(kubectl get pods --all-namespaces --no-headers | \
        grep -E "(Pending|Failed|CrashLoopBackOff|ImagePullBackOff|Error)" | wc -l)
    
    if [[ $problematic_pods -gt 0 ]]; then
        echo -e "\n${YELLOW}Warning: $problematic_pods pods in problematic states${NC}"
        kubectl get pods --all-namespaces --no-headers | \
            grep -E "(Pending|Failed|CrashLoopBackOff|ImagePullBackOff|Error)" | \
            head -10
    fi
}

# Check resource utilization
check_resource_utilization() {
    log "INFO" "Checking cluster resource utilization..."
    
    local cpu_threshold=$(get_config "thresholds.cpu_warning")
    local memory_threshold=$(get_config "thresholds.memory_warning")
    
    echo -e "\n${CYAN}=== Resource Utilization ===${NC}"
    
    # Check if metrics server is available
    if ! kubectl top nodes &> /dev/null; then
        log "WARN" "Metrics server not available, skipping resource utilization check"
        return
    fi
    
    # Node resource usage with thresholds
    kubectl top nodes --no-headers | while read -r node cpu cpu_percent memory memory_percent; do
        # Extract percentage values
        cpu_val=$(echo "$cpu_percent" | sed 's/%//')
        mem_val=$(echo "$memory_percent" | sed 's/%//')
        
        # Color code based on thresholds
        local cpu_color="$GREEN"
        local mem_color="$GREEN"
        
        if [[ ${cpu_val%.*} -ge $cpu_threshold ]]; then
            cpu_color="$RED"
            log "WARN" "Node $node CPU usage high: $cpu_percent"
        fi
        
        if [[ ${mem_val%.*} -ge $memory_threshold ]]; then
            mem_color="$RED"
            log "WARN" "Node $node Memory usage high: $memory_percent"
        fi
        
        echo -e "Node: $node | CPU: ${cpu_color}$cpu_percent${NC} | Memory: ${mem_color}$memory_percent${NC}"
    done
}

# Check system components
check_system_components() {
    echo -e "\n${CYAN}=== System Component Health ===${NC}"
    
    # Check system pods
    local system_pods_down=$(kubectl get pods -n kube-system --no-headers | grep -v Running | wc -l)
    if [[ $system_pods_down -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $system_pods_down system pods not running${NC}"
        kubectl get pods -n kube-system --no-headers | grep -v Running | head -5
    else
        echo -e "${GREEN}All system pods are running${NC}"
    fi
    
    # Check persistent volumes
    local pv_issues=$(kubectl get pv --no-headers | grep -v Bound | wc -l)
    if [[ $pv_issues -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $pv_issues persistent volumes not bound${NC}"
        kubectl get pv --no-headers | grep -v Bound | head -5
    else
        echo -e "${GREEN}All persistent volumes are bound${NC}"
    fi
}

# Check storage capacity
check_storage_capacity() {
    echo -e "\n${CYAN}=== Storage Capacity ===${NC}"
    
    # Check PVC usage
    kubectl get pvc --all-namespaces -o json | jq -r '
        .items[] | 
        "\(.metadata.namespace)/\(.metadata.name): \(.status.capacity.storage // "N/A")"
    ' | head -10
    
    # Check for storage classes
    local storage_classes=$(kubectl get storageclass --no-headers | wc -l)
    echo "Available Storage Classes: $storage_classes"
}

# Comprehensive health check
cluster_health_check() {
    log "INFO" "Starting comprehensive cluster health check..."
    
    check_node_status
    check_pod_distribution
    check_resource_utilization
    check_system_components
    check_storage_capacity
    
    log "INFO" "Cluster health check completed"
}