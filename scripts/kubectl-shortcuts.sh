#!/bin/bash

#==============================================================================
# Kubectl Shortcuts Module
# Enhanced kubectl functions with error handling and convenience features
#==============================================================================

# Enhanced kubectl logs with pattern matching
kube_logs() {
    local namespace="${1:-default}"
    local pod_pattern="$2"
    local lines="${3:-100}"
    
    if [[ -z "$pod_pattern" ]]; then
        log "ERROR" "Pod pattern is required"
        return 1
    fi
    
    log "INFO" "Getting logs for pods matching '$pod_pattern' in namespace '$namespace'"
    
    local pods=$(kubectl get pods -n "$namespace" --no-headers | grep "$pod_pattern" | awk '{print $1}')
    
    if [[ -z "$pods" ]]; then
        log "WARN" "No pods found matching pattern '$pod_pattern' in namespace '$namespace'"
        return 1
    fi
    
    for pod in $pods; do
        echo -e "\n${CYAN}=== Logs for $pod ===${NC}"
        kubectl logs -n "$namespace" "$pod" --tail="$lines" || log "ERROR" "Failed to get logs for $pod"
    done
}

# Safe pod exec with validation
kube_exec() {
    local namespace="${1:-default}"
    local pod_pattern="$2"
    local command="${3:-/bin/bash}"
    
    if [[ -z "$pod_pattern" ]]; then
        log "ERROR" "Pod pattern is required"
        return 1
    fi
    
    local pod=$(kubectl get pods -n "$namespace" --no-headers | grep "$pod_pattern" | grep Running | head -1 | awk '{print $1}')
    
    if [[ -z "$pod" ]]; then
        log "ERROR" "No running pod found matching pattern '$pod_pattern' in namespace '$namespace'"
        return 1
    fi
    
    log "INFO" "Executing command in pod $pod"
    kubectl exec -it -n "$namespace" "$pod" -- "$command"
}

# Port forward with automatic cleanup
kube_port_forward() {
    local namespace="${1:-default}"
    local pod_pattern="$2"
    local local_port="$3"
    local remote_port="$4"
    
    if [[ -z "$pod_pattern" || -z "$local_port" || -z "$remote_port" ]]; then
        log "ERROR" "Usage: kube_port_forward <namespace> <pod_pattern> <local_port> <remote_port>"
        return 1
    fi
    
    local pod=$(kubectl get pods -n "$namespace" --no-headers | grep "$pod_pattern" | grep Running | head -1 | awk '{print $1}')
    
    if [[ -z "$pod" ]]; then
        log "ERROR" "No running pod found matching pattern '$pod_pattern' in namespace '$namespace'"
        return 1
    fi
    
    log "INFO" "Port forwarding $local_port -> $pod:$remote_port"
    echo "Press Ctrl+C to stop port forwarding"
    kubectl port-forward -n "$namespace" "$pod" "$local_port:$remote_port"
}

# Describe resources with enhanced output
kube_describe() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-default}"
    
    if [[ -z "$resource_type" || -z "$resource_name" ]]; then
        log "ERROR" "Usage: kube_describe <resource_type> <resource_name> [namespace]"
        return 1
    fi
    
    log "INFO" "Describing $resource_type/$resource_name in namespace $namespace"
    kubectl describe "$resource_type" "$resource_name" -n "$namespace"
}

# Get pod events
kube_events() {
    local namespace="${1:-default}"
    local resource_name="$2"
    
    log "INFO" "Getting events for namespace '$namespace'"
    
    if [[ -n "$resource_name" ]]; then
        kubectl get events -n "$namespace" --field-selector involvedObject.name="$resource_name" --sort-by='.lastTimestamp'
    else
        kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -20
    fi
}

# Quick pod status check
kube_pod_status() {
    local namespace="${1:-default}"
    
    echo -e "\n${CYAN}=== Pod Status in namespace: $namespace ===${NC}"
    kubectl get pods -n "$namespace" -o wide
    
    # Show any problematic pods with details
    local problematic=$(kubectl get pods -n "$namespace" --no-headers | grep -E "(Pending|Failed|CrashLoopBackOff|ImagePullBackOff|Error)")
    
    if [[ -n "$problematic" ]]; then
        echo -e "\n${YELLOW}=== Problematic Pods ===${NC}"
        echo "$problematic"
    fi
}

# Resource usage for specific namespace
kube_resource_usage() {
    local namespace="${1:-default}"
    
    echo -e "\n${CYAN}=== Resource Usage in namespace: $namespace ===${NC}"
    
    if kubectl top pods -n "$namespace" &> /dev/null; then
        kubectl top pods -n "$namespace"
    else
        log "WARN" "Metrics server not available for resource usage"
    fi
}

# Copy files to/from pods
kube_copy() {
    local direction="$1"  # "to" or "from"
    local namespace="${2:-default}"
    local pod_pattern="$3"
    local source="$4"
    local destination="$5"
    
    if [[ -z "$direction" || -z "$pod_pattern" || -z "$source" || -z "$destination" ]]; then
        log "ERROR" "Usage: kube_copy <to|from> <namespace> <pod_pattern> <source> <destination>"
        return 1
    fi
    
    local pod=$(kubectl get pods -n "$namespace" --no-headers | grep "$pod_pattern" | grep Running | head -1 | awk '{print $1}')
    
    if [[ -z "$pod" ]]; then
        log "ERROR" "No running pod found matching pattern '$pod_pattern' in namespace '$namespace'"
        return 1
    fi
    
    case "$direction" in
        "to")
            log "INFO" "Copying $source to $pod:$destination"
            kubectl cp "$source" "$namespace/$pod:$destination"
            ;;
        "from")
            log "INFO" "Copying $pod:$source to $destination"
            kubectl cp "$namespace/$pod:$source" "$destination"
            ;;
        *)
            log "ERROR" "Direction must be 'to' or 'from'"
            return 1
            ;;
    esac
}

# Quick namespace overview
kube_namespace_overview() {
    local namespace="${1:-default}"
    
    echo -e "\n${CYAN}=== Namespace Overview: $namespace ===${NC}"
    
    # Pod summary
    local total_pods=$(kubectl get pods -n "$namespace" --no-headers | wc -l)
    local running_pods=$(kubectl get pods -n "$namespace" --no-headers | grep Running | wc -l)
    local pending_pods=$(kubectl get pods -n "$namespace" --no-headers | grep Pending | wc -l)
    local failed_pods=$(kubectl get pods -n "$namespace" --no-headers | grep -E "(Failed|Error|CrashLoopBackOff)" | wc -l)
    
    echo "Pods: Total=$total_pods, Running=$running_pods, Pending=$pending_pods, Failed=$failed_pods"
    
    # Service summary
    local services=$(kubectl get services -n "$namespace" --no-headers | wc -l)
    echo "Services: $services"
    
    # ConfigMap and Secret summary
    local configmaps=$(kubectl get configmaps -n "$namespace" --no-headers | wc -l)
    local secrets=$(kubectl get secrets -n "$namespace" --no-headers | wc -l)
    echo "ConfigMaps: $configmaps, Secrets: $secrets"
    
    # PVC summary
    local pvcs=$(kubectl get pvc -n "$namespace" --no-headers | wc -l)
    echo "PersistentVolumeClaims: $pvcs"
}