#!/bin/bash

#==============================================================================
# Log Collection Module
# Functions for collecting and aggregating logs from pods and nodes
#==============================================================================

# Collect logs from critical pods
collect_critical_logs() {
    local output_dir="${1:-$TEMP_DIR/logs}"
    local lines="${2:-$(get_config 'log_lines')}"
    
    log "INFO" "Collecting logs from critical pods..."
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    # Get critical patterns from config
    local critical_patterns
    critical_patterns=$(get_config 'log_collection.critical_patterns' | jq -r '.[]' 2>/dev/null || echo "kube-apiserver etcd kube-controller kube-scheduler coredns ingress")
    
    for pattern in $critical_patterns; do
        log "INFO" "Collecting logs for pattern: $pattern"
        
        kubectl get pods --all-namespaces --no-headers | grep "$pattern" | while read -r namespace name _; do
            local log_file="$output_dir/${namespace}_${name}_${timestamp}.log"
            
            log "DEBUG" "Collecting logs from $namespace/$name"
            kubectl logs -n "$namespace" "$name" --tail="$lines" > "$log_file" 2>&1 || \
                log "WARN" "Failed to collect logs from $namespace/$name"
        done
    done
    
    # Create archive
    local archive_file="$output_dir/../critical_logs_${timestamp}.tar.gz"
    tar -czf "$archive_file" -C "$output_dir" . || {
        log "ERROR" "Failed to create log archive"
        return 1
    }
    
    log "INFO" "Critical logs collected and archived: $archive_file"
    echo "Log archive created: $archive_file"
}

# Collect logs from problematic pods
collect_problematic_pod_logs() {
    local output_dir="${1:-$TEMP_DIR/problematic_logs}"
    local lines="${2:-500}"
    
    log "INFO" "Collecting logs from problematic pods..."
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    # Find problematic pods
    kubectl get pods --all-namespaces --no-headers | \
        grep -E "(Pending|Failed|CrashLoopBackOff|ImagePullBackOff|Error)" | \
        while read -r namespace name status _; do
            local log_file="$output_dir/${namespace}_${name}_${status}_${timestamp}.log"
            
            log "INFO" "Collecting logs from problematic pod: $namespace/$name ($status)"
            
            # Get current logs
            kubectl logs -n "$namespace" "$name" --tail="$lines" > "$log_file" 2>&1
            
            # Get previous logs if available
            kubectl logs -n "$namespace" "$name" --previous --tail="$lines" >> "$log_file" 2>&1 || true
            
            # Get pod events
            echo -e "\n=== Pod Events ===" >> "$log_file"
            kubectl get events -n "$namespace" --field-selector involvedObject.name="$name" >> "$log_file" 2>&1
        done
    
    # Create archive
    local archive_file="$output_dir/../problematic_logs_${timestamp}.tar.gz"
    tar -czf "$archive_file" -C "$output_dir" . 2>/dev/null || {
        log "WARN" "No problematic pods found or failed to create archive"
        return 1
    }
    
    log "INFO" "Problematic pod logs archived: $archive_file"
    echo "Problematic pod logs archive: $archive_file"
}

# Collect systemd logs from nodes
collect_systemd_logs() {
    local service="${1:-kubelet}"
    local lines="${2:-1000}"
    local output_dir="${3:-$TEMP_DIR/systemd_logs}"
    
    log "INFO" "Collecting systemd logs for service: $service"
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    kubectl get nodes --no-headers | awk '{print $1}' | while read -r node; do
        log "INFO" "Collecting $service logs from node: $node"
        local log_file="$output_dir/${node}_${service}_${timestamp}.log"
        
        # Try to collect logs using kubectl debug
        if kubectl debug node/"$node" -it --image=alpine -- sh -c "chroot /host journalctl -u $service -n $lines" > "$log_file" 2>/dev/null; then
            log "DEBUG" "Successfully collected $service logs from $node"
        else
            log "WARN" "Failed to collect $service logs from $node"
            echo "Failed to collect logs from $node" > "$log_file"
        fi
    done
    
    # Create archive
    local archive_file="$output_dir/../systemd_${service}_logs_${timestamp}.tar.gz"
    tar -czf "$archive_file" -C "$output_dir" . || {
        log "ERROR" "Failed to create systemd log archive"
        return 1
    }
    
    log "INFO" "Systemd log collection completed: $archive_file"
    echo "Systemd logs archive: $archive_file"
}

# Collect logs based on time range
collect_logs_by_timerange() {
    local namespace="${1:-default}"
    local pod_pattern="$2"
    local since="${3:-1h}"
    local output_dir="${4:-$TEMP_DIR/timerange_logs}"
    
    if [[ -z "$pod_pattern" ]]; then
        log "ERROR" "Pod pattern is required"
        return 1
    fi
    
    log "INFO" "Collecting logs from last $since for pods matching '$pod_pattern'"
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    kubectl get pods -n "$namespace" --no-headers | grep "$pod_pattern" | while read -r pod _; do
        local log_file="$output_dir/${namespace}_${pod}_since_${since}_${timestamp}.log"
        
        log "DEBUG" "Collecting logs from $namespace/$pod since $since"
        kubectl logs -n "$namespace" "$pod" --since="$since" > "$log_file" 2>&1 || \
            log "WARN" "Failed to collect logs from $namespace/$pod"
    done
    
    log "INFO" "Time-range log collection completed"
}

# Collect cluster events
collect_cluster_events() {
    local output_dir="${1:-$TEMP_DIR/events}"
    local since="${2:-1h}"
    
    log "INFO" "Collecting cluster events from last $since"
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local events_file="$output_dir/cluster_events_${timestamp}.log"
    
    # Collect events sorted by time
    kubectl get events --all-namespaces --sort-by='.lastTimestamp' > "$events_file"
    
    # Collect events in JSON format for analysis
    kubectl get events --all-namespaces -o json > "$output_dir/cluster_events_${timestamp}.json"
    
    # Filter warning and error events
    kubectl get events --all-namespaces --field-selector type=Warning --sort-by='.lastTimestamp' > "$output_dir/warning_events_${timestamp}.log"
    
    log "INFO" "Cluster events collected in $output_dir"
    echo "Events collected in: $output_dir"
}

# Collect application logs with filtering
collect_application_logs() {
    local namespace="$1"
    local app_label="$2"
    local grep_pattern="${3:-ERROR}"
    local lines="${4:-1000}"
    local output_dir="${5:-$TEMP_DIR/app_logs}"
    
    if [[ -z "$namespace" || -z "$app_label" ]]; then
        log "ERROR" "Namespace and app label are required"
        return 1
    fi
    
    log "INFO" "Collecting application logs for app=$app_label in namespace $namespace"
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    # Find pods with the app label
    kubectl get pods -n "$namespace" -l "app=$app_label" --no-headers | while read -r pod _; do
        local log_file="$output_dir/${namespace}_${pod}_filtered_${timestamp}.log"
        
        log "DEBUG" "Collecting filtered logs from $namespace/$pod"
        
        # Collect all logs first, then filter
        kubectl logs -n "$namespace" "$pod" --tail="$lines" | grep "$grep_pattern" > "$log_file" 2>&1 || \
            log "WARN" "No matching logs found for $namespace/$pod with pattern '$grep_pattern'"
    done
    
    log "INFO" "Application log collection completed"
}

# Generate log summary report
generate_log_summary() {
    local output_dir="${1:-$TEMP_DIR/log_summary}"
    
    log "INFO" "Generating log summary report..."
    
    mkdir -p "$output_dir"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local report_file="$output_dir/log_summary_${timestamp}.txt"
    
    {
        echo "=== Kubernetes Cluster Log Summary ==="
        echo "Generated: $(date)"
        echo "Cluster: $(kubectl config current-context)"
        echo
        
        echo "=== Pod Status Summary ==="
        kubectl get pods --all-namespaces --no-headers | awk '{print $4}' | sort | uniq -c
        echo
        
        echo "=== Recent Events (Last 20) ==="
        kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -20
        echo
        
        echo "=== Nodes with Issues ==="
        kubectl get nodes --no-headers | grep -v " Ready " || echo "All nodes are ready"
        echo
        
        echo "=== Persistent Volume Issues ==="
        kubectl get pv --no-headers | grep -v Bound || echo "All PVs are bound"
        echo
        
        echo "=== Top Resource Consuming Pods ==="
        kubectl top pods --all-namespaces --sort-by=memory 2>/dev/null | head -10 || echo "Metrics server not available"
        
    } > "$report_file"
    
    log "INFO" "Log summary report generated: $report_file"
    echo "Log summary report: $report_file"
}

# Clean old log files
cleanup_old_logs() {
    local log_base_dir="${1:-$TEMP_DIR}"
    local days="${2:-$(get_config 'retention_days')}"
    
    log "INFO" "Cleaning log files older than $days days in $log_base_dir"
    
    find "$log_base_dir" -name "*.log" -o -name "*.tar.gz" -type f -mtime +$days -delete 2>/dev/null || true
    
    log "INFO" "Old log cleanup completed"
}