#!/bin/bash

#==============================================================================
# Resource Cleanup Module
# Functions for cleaning up unused and problematic resources
#==============================================================================

# Clean up evicted pods
cleanup_evicted_pods() {
    local force="${1:-false}"
    
    log "INFO" "Checking for evicted pods..."
    
    local evicted_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | \
        jq -r '.items[] | select(.status.reason == "Evicted") | "\(.metadata.namespace) \(.metadata.name)"')
    
    if [[ -z "$evicted_pods" ]]; then
        log "INFO" "No evicted pods found"
        return 0
    fi
    
    echo -e "\n${YELLOW}=== Evicted Pods ===${NC}"
    echo "$evicted_pods"
    
    local count=$(echo "$evicted_pods" | wc -l)
    
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Delete $count evicted pods?"; then
            log "INFO" "Evicted pod cleanup cancelled"
            return 0
        fi
    fi
    
    log "INFO" "Deleting evicted pods..."
    echo "$evicted_pods" | while read -r namespace pod; do
        kubectl delete pod -n "$namespace" "$pod" || \
            log "WARN" "Failed to delete evicted pod $namespace/$pod"
    done
    
    log "INFO" "Evicted pod cleanup completed"
}

# Clean up completed jobs
cleanup_completed_jobs() {
    local retention_days="${1:-$(get_config 'retention_days')}"
    local force="${2:-false}"
    
    log "INFO" "Checking for completed jobs older than $retention_days days..."
    
    local cutoff_date=$(date -d "$retention_days days ago" '+%Y-%m-%dT%H:%M:%SZ')
    
    local old_jobs=$(kubectl get jobs --all-namespaces -o json | \
        jq -r --arg cutoff "$cutoff_date" '
        .items[] | 
        select(.status.completionTime and .status.completionTime < $cutoff) |
        "\(.metadata.namespace) \(.metadata.name)"')
    
    if [[ -z "$old_jobs" ]]; then
        log "INFO" "No old completed jobs found"
        return 0
    fi
    
    echo -e "\n${YELLOW}=== Old Completed Jobs ===${NC}"
    echo "$old_jobs"
    
    local count=$(echo "$old_jobs" | wc -l)
    
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Delete $count old completed jobs?"; then
            log "INFO" "Completed job cleanup cancelled"
            return 0
        fi
    fi
    
    log "INFO" "Deleting old completed jobs..."
    echo "$old_jobs" | while read -r namespace job; do
        kubectl delete job -n "$namespace" "$job" || \
            log "WARN" "Failed to delete job $namespace/$job"
    done
    
    log "INFO" "Completed job cleanup finished"
}

# Clean up failed jobs
cleanup_failed_jobs() {
    local force="${1:-false}"
    
    log "INFO" "Checking for failed jobs..."
    
    local failed_jobs=$(kubectl get jobs --all-namespaces -o json | \
        jq -r '.items[] | select(.status.failed and .status.failed > 0) | "\(.metadata.namespace) \(.metadata.name)"')
    
    if [[ -z "$failed_jobs" ]]; then
        log "INFO" "No failed jobs found"
        return 0
    fi
    
    echo -e "\n${YELLOW}=== Failed Jobs ===${NC}"
    echo "$failed_jobs"
    
    local count=$(echo "$failed_jobs" | wc -l)
    
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Delete $count failed jobs?"; then
            log "INFO" "Failed job cleanup cancelled"
            return 0
        fi
    fi
    
    log "INFO" "Deleting failed jobs..."
    echo "$failed_jobs" | while read -r namespace job; do
        kubectl delete job -n "$namespace" "$job" || \
            log "WARN" "Failed to delete job $namespace/$job"
    done
    
    log "INFO" "Failed job cleanup completed"
}

# Clean up unused ConfigMaps and Secrets
cleanup_unused_resources() {
    local force="${1:-false}"
    local resource_type="${2:-configmap}"
    
    log "INFO" "Checking for unused ${resource_type}s..."
    
    echo -e "\n${CYAN}=== Unused Resource Cleanup ===${NC}"
    echo "Note: This performs basic checks. Manual verification recommended."
    
    # Get all namespaces except excluded ones
    local all_namespaces=$(kubectl get namespaces --no-headers | awk '{print $1}')
    
    for namespace in $all_namespaces; do
        # Skip excluded namespaces
        if is_namespace_excluded "$namespace"; then
            continue
        fi
        
        case "$resource_type" in
            "configmap")
                cleanup_unused_configmaps "$namespace" "$force"
                ;;
            "secret")
                cleanup_unused_secrets "$namespace" "$force"
                ;;
            *)
                log "ERROR" "Unsupported resource type: $resource_type"
                return 1
                ;;
        esac
    done
    
    log "INFO" "Unused resource check completed"
}

# Helper function to check unused ConfigMaps in a namespace
cleanup_unused_configmaps() {
    local namespace="$1"
    local force="${2:-false}"
    
    kubectl get configmaps -n "$namespace" --no-headers | while read -r cm _; do
        # Skip default ConfigMaps
        if [[ "$cm" =~ ^(kube-root-ca.crt|default-token-.*|.*-token-.*)$ ]]; then
            continue
        fi
        
        # Check if ConfigMap is referenced by any pods
        local references=$(kubectl get pods -n "$namespace" -o json | \
            jq -r --arg cm "$cm" '
            .items[] | 
            select(.spec.volumes[]?.configMap?.name == $cm or 
                   .spec.containers[]?.env[]?.valueFrom?.configMapKeyRef?.name == $cm or
                   .spec.containers[]?.envFrom[]?.configMapRef?.name == $cm) |
            .metadata.name' | wc -l)
        
        if [[ $references -eq 0 ]]; then
            echo "Potentially unused ConfigMap: $namespace/$cm"
            
            if [[ "$force" == "true" ]] || confirm_action "Delete unused ConfigMap $namespace/$cm?"; then
                kubectl delete configmap -n "$namespace" "$cm" || \
                    log "WARN" "Failed to delete ConfigMap $namespace/$cm"
            fi
        fi
    done
}

# Helper function to check unused Secrets in a namespace
cleanup_unused_secrets() {
    local namespace="$1"
    local force="${2:-false}"
    
    kubectl get secrets -n "$namespace" --no-headers | while read -r secret type _; do
        # Skip service account tokens and TLS secrets
        if [[ "$type" =~ ^(kubernetes.io/service-account-token|kubernetes.io/tls)$ ]]; then
            continue
        fi
        
        # Check if Secret is referenced by any pods
        local references=$(kubectl get pods -n "$namespace" -o json | \
            jq -r --arg secret "$secret" '
            .items[] | 
            select(.spec.volumes[]?.secret?.secretName == $secret or 
                   .spec.containers[]?.env[]?.valueFrom?.secretKeyRef?.name == $secret or
                   .spec.containers[]?.envFrom[]?.secretRef?.name == $secret or
                   .spec.imagePullSecrets[]?.name == $secret) |
            .metadata.name' | wc -l)
        
        if [[ $references -eq 0 ]]; then
            echo "Potentially unused Secret: $namespace/$secret"
            
            if [[ "$force" == "true" ]] || confirm_action "Delete unused Secret $namespace/$secret?"; then
                kubectl delete secret -n "$namespace" "$secret" || \
                    log "WARN" "Failed to delete Secret $namespace/$secret"
            fi
        fi
    done
}

# Clean up orphaned PVCs
cleanup_orphaned_pvcs() {
    local force="${1:-false}"
    
    log "INFO" "Checking for orphaned PVCs..."
    
    local orphaned_pvcs=""
    
    kubectl get pvc --all-namespaces --no-headers | while read -r namespace pvc status volume _; do
        # Check if PVC is used by any pod
        local pod_count=$(kubectl get pods -n "$namespace" -o json | \
            jq -r --arg pvc "$pvc" '.items[] | select(.spec.volumes[]?.persistentVolumeClaim?.claimName == $pvc) | .metadata.name' | wc -l)
        
        if [[ $pod_count -eq 0 && "$status" == "Bound" ]]; then
            echo "Orphaned PVC: $namespace/$pvc (Volume: $volume)"
            orphaned_pvcs="$orphaned_pvcs $namespace/$pvc"
        fi
    done
    
    if [[ -z "$orphaned_pvcs" ]]; then
        log "INFO" "No orphaned PVCs found"
        return 0
    fi
    
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Delete orphaned PVCs? (This will also delete the underlying storage!)"; then
            log "INFO" "Orphaned PVC cleanup cancelled"
            return 0
        fi
    fi
    
    echo "$orphaned_pvcs" | tr ' ' '\n' | while IFS='/' read -r namespace pvc; do
        [[ -n "$namespace" && -n "$pvc" ]] || continue
        log "INFO" "Deleting orphaned PVC: $namespace/$pvc"
        kubectl delete pvc -n "$namespace" "$pvc" || \
            log "WARN" "Failed to delete PVC $namespace/$pvc"
    done
    
    log "INFO" "Orphaned PVC cleanup completed"
}

# Clean up terminated pods
cleanup_terminated_pods() {
    local force="${1:-false}"
    
    log "INFO" "Checking for terminated pods..."
    
    local terminated_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Succeeded --no-headers)
    
    if [[ -z "$terminated_pods" ]]; then
        log "INFO" "No terminated pods found"
        return 0
    fi
    
    echo -e "\n${YELLOW}=== Terminated (Succeeded) Pods ===${NC}"
    echo "$terminated_pods"
    
    local count=$(echo "$terminated_pods" | wc -l)
    
    if [[ "$force" != "true" ]]; then
        if ! confirm_action "Delete $count terminated pods?"; then
            log "INFO" "Terminated pod cleanup cancelled"
            return 0
        fi
    fi
    
    log "INFO" "Deleting terminated pods..."
    echo "$terminated_pods" | while read -r namespace pod _; do
        kubectl delete pod -n "$namespace" "$pod" || \
            log "WARN" "Failed to delete terminated pod $namespace/$pod"
    done
    
    log "INFO" "Terminated pod cleanup completed"
}

# Comprehensive cleanup function
comprehensive_cleanup() {
    local force="${1:-false}"
    
    log "INFO" "Starting comprehensive resource cleanup..."
    
    # Check configuration for enabled cleanup types
    local cleanup_evicted=$(get_config 'cleanup.evicted_pods')
    local cleanup_jobs=$(get_config 'cleanup.completed_jobs')
    local cleanup_configmaps=$(get_config 'cleanup.unused_configmaps')
    local cleanup_secrets=$(get_config 'cleanup.unused_secrets')
    
    if [[ "$cleanup_evicted" == "true" ]]; then
        cleanup_evicted_pods "$force"
    fi
    
    if [[ "$cleanup_jobs" == "true" ]]; then
        cleanup_completed_jobs "$(get_config 'retention_days')" "$force"
        cleanup_failed_jobs "$force"
    fi
    
    if [[ "$cleanup_configmaps" == "true" ]]; then
        cleanup_unused_resources "$force" "configmap"
    fi
    
    if [[ "$cleanup_secrets" == "true" ]]; then
        cleanup_unused_resources "$force" "secret"
    fi
    
    # Always offer to clean up terminated pods and orphaned PVCs
    cleanup_terminated_pods "$force"
    cleanup_orphaned_pvcs "$force"
    
    log "INFO" "Comprehensive cleanup completed"
}