#!/bin/bash

#==============================================================================
# Security Checks Module
# Functions for scanning and reporting security issues in the cluster
#==============================================================================

# Check for privileged pods
check_privileged_pods() {
    log "INFO" "Checking for privileged pods..."
    
    echo -e "\n${CYAN}=== Privileged Pods ===${NC}"
    
    local privileged_pods=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | 
        select(.spec.containers[]?.securityContext?.privileged == true or 
               .spec.securityContext?.privileged == true) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    
    if [[ -z "$privileged_pods" ]]; then
        echo -e "${GREEN}No privileged pods found${NC}"
    else
        echo -e "${RED}Privileged pods detected:${NC}"
        echo "$privileged_pods"
        log "WARN" "Privileged pods detected: $(echo "$privileged_pods" | tr '\n' ' ')"
    fi
}

# Check for hostPath mounts
check_hostpath_mounts() {
    log "INFO" "Checking for hostPath mounts..."
    
    echo -e "\n${CYAN}=== HostPath Mounts ===${NC}"
    
    local hostpath_pods=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | 
        select(.spec.volumes[]?.hostPath) |
        "\(.metadata.namespace)/\(.metadata.name): \(.spec.volumes[] | select(.hostPath) | .hostPath.path)"')
    
    if [[ -z "$hostpath_pods" ]]; then
        echo -e "${GREEN}No hostPath mounts found${NC}"
    else
        echo -e "${YELLOW}Pods with hostPath mounts:${NC}"
        echo "$hostpath_pods"
        log "WARN" "HostPath mounts detected"
    fi
}

# Check for hostNetwork usage
check_host_network() {
    log "INFO" "Checking for pods using host network..."
    
    echo -e "\n${CYAN}=== Host Network Usage ===${NC}"
    
    local host_network_pods=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | select(.spec.hostNetwork == true) | "\(.metadata.namespace)/\(.metadata.name)"')
    
    if [[ -z "$host_network_pods" ]]; then
        echo -e "${GREEN}No pods using host network found${NC}"
    else
        echo -e "${YELLOW}Pods using host network:${NC}"
        echo "$host_network_pods"
        log "WARN" "Pods using host network detected"
    fi
}

# Check for pods running as root
check_root_users() {
    log "INFO" "Checking for pods running as root..."
    
    echo -e "\n${CYAN}=== Root User Check ===${NC}"
    
    local root_pods=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | 
        select(.spec.containers[]?.securityContext?.runAsUser == 0 or 
               (.spec.securityContext?.runAsUser == 0) or
               (.spec.containers[]?.securityContext?.runAsUser // .spec.securityContext?.runAsUser // 0) == 0) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    
    if [[ -z "$root_pods" ]]; then
        echo -e "${GREEN}No pods explicitly running as root found${NC}"
    else
        echo -e "${YELLOW}Pods running as root:${NC}"
        echo "$root_pods" | head -10
        log "WARN" "Pods running as root detected"
    fi
}

# Basic RBAC check
check_rbac_configuration() {
    log "INFO" "Checking RBAC configuration..."
    
    echo -e "\n${CYAN}=== RBAC Analysis ===${NC}"
    
    # Check for cluster-admin bindings
    echo -e "\n${YELLOW}Cluster Admin Bindings:${NC}"
    local cluster_admin_bindings=$(kubectl get clusterrolebindings -o json | \
        jq -r '.items[] | 
        select(.roleRef.name == "cluster-admin") |
        "\(.metadata.name): \(.subjects[]?.name // .subjects[]?.serviceAccount // "N/A")"')
    
    if [[ -n "$cluster_admin_bindings" ]]; then
        echo "$cluster_admin_bindings"
        log "WARN" "Cluster admin bindings found"
    else
        echo "No cluster-admin bindings found"
    fi
    
    # Check for overly permissive roles
    echo -e "\n${YELLOW}Roles with wildcard permissions:${NC}"
    local wildcard_roles=$(kubectl get clusterroles -o json | \
        jq -r '.items[] | 
        select(.rules[]? | .verbs[]? == "*" or .resources[]? == "*") |
        .metadata.name' | head -10)
    
    if [[ -n "$wildcard_roles" ]]; then
        echo "$wildcard_roles"
        log "WARN" "Roles with wildcard permissions found"
    else
        echo "No roles with wildcard permissions found"
    fi
}

# Check for service accounts with automount tokens
check_service_account_tokens() {
    log "INFO" "Checking service account token automounting..."
    
    echo -e "\n${CYAN}=== Service Account Token Analysis ===${NC}"
    
    # Check for pods with automounted service account tokens
    local automount_pods=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | 
        select(.spec.automountServiceAccountToken != false and 
               (.spec.serviceAccountName // "default") != "default") |
        "\(.metadata.namespace)/\(.metadata.name) (SA: \(.spec.serviceAccountName // "default"))"')
    
    if [[ -n "$automount_pods" ]]; then
        echo -e "${YELLOW}Pods with automounted service account tokens:${NC}"
        echo "$automount_pods" | head -10
    else
        echo -e "${GREEN}No concerning service account token usage found${NC}"
    fi
}

# Check for insecure capabilities
check_capabilities() {
    log "INFO" "Checking for dangerous capabilities..."
    
    echo -e "\n${CYAN}=== Capability Analysis ===${NC}"
    
    local dangerous_caps=("SYS_ADMIN" "NET_ADMIN" "SYS_PTRACE" "SYS_MODULE" "DAC_OVERRIDE")
    
    for cap in "${dangerous_caps[@]}"; do
        local pods_with_cap=$(kubectl get pods --all-namespaces -o json | \
            jq -r --arg cap "$cap" '.items[] | 
            select(.spec.containers[]?.securityContext?.capabilities?.add[]? == $cap) |
            "\(.metadata.namespace)/\(.metadata.name)"')
        
        if [[ -n "$pods_with_cap" ]]; then
            echo -e "${RED}Pods with $cap capability:${NC}"
            echo "$pods_with_cap"
            log "WARN" "Pods with dangerous capability $cap detected"
        fi
    done
}

# Check for network policies
check_network_policies() {
    log "INFO" "Checking network policy coverage..."
    
    echo -e "\n${CYAN}=== Network Policy Analysis ===${NC}"
    
    # Check if network policies exist
    local total_policies=$(kubectl get networkpolicies --all-namespaces --no-headers | wc -l)
    echo "Total Network Policies: $total_policies"
    
    if [[ $total_policies -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No network policies found. Network traffic is not restricted.${NC}"
        log "WARN" "No network policies found"
    else
        # Check namespaces without network policies
        local namespaces_without_policies=$(kubectl get namespaces --no-headers | awk '{print $1}' | while read -r ns; do
            if ! is_namespace_excluded "$ns"; then
                local policy_count=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
                if [[ $policy_count -eq 0 ]]; then
                    echo "$ns"
                fi
            fi
        done)
        
        if [[ -n "$namespaces_without_policies" ]]; then
            echo -e "${YELLOW}Namespaces without network policies:${NC}"
            echo "$namespaces_without_policies"
        else
            echo -e "${GREEN}All user namespaces have network policies${NC}"
        fi
    fi
}

# Check for pod security standards
check_pod_security_standards() {
    log "INFO" "Checking Pod Security Standards compliance..."
    
    echo -e "\n${CYAN}=== Pod Security Standards ===${NC}"
    
    # Check for Pod Security Standards labels on namespaces
    kubectl get namespaces -o json | jq -r '.items[] | 
        "\(.metadata.name): \(.metadata.labels["pod-security.kubernetes.io/enforce"] // "none")"' | \
        while IFS=': ' read -r namespace level; do
            if ! is_namespace_excluded "$namespace"; then
                if [[ "$level" == "none" ]]; then
                    echo -e "${YELLOW}Namespace $namespace: No Pod Security Standard enforced${NC}"
                else
                    echo -e "${GREEN}Namespace $namespace: $level level enforced${NC}"
                fi
            fi
        done
}

# Check for image vulnerabilities (basic)
check_image_security() {
    log "INFO" "Performing basic image security checks..."
    
    echo -e "\n${CYAN}=== Image Security Analysis ===${NC}"
    
    # Check for images using latest tag
    echo -e "\n${YELLOW}Images using 'latest' tag:${NC}"
    local latest_images=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | .spec.containers[] | 
        select(.image | endswith(":latest") or (contains(":") | not)) |
        .image' | sort | uniq)
    
    if [[ -n "$latest_images" ]]; then
        echo "$latest_images"
        log "WARN" "Images using latest tag detected"
    else
        echo -e "${GREEN}No images using latest tag found${NC}"
    fi
    
    # Check for images from unofficial registries
    echo -e "\n${YELLOW}Images from potentially untrusted registries:${NC}"
    local untrusted_images=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | .spec.containers[] | 
        select(.image | test("^[^/]+/") and (test("^(docker.io|gcr.io|k8s.gcr.io|quay.io|registry.k8s.io)") | not)) |
        .image' | sort | uniq | head -10)
    
    if [[ -n "$untrusted_images" ]]; then
        echo "$untrusted_images"
        log "WARN" "Images from potentially untrusted registries detected"
    else
        echo -e "${GREEN}All images appear to be from trusted registries${NC}"
    fi
}

# Check for resource limits
check_resource_limits() {
    log "INFO" "Checking for missing resource limits..."
    
    echo -e "\n${CYAN}=== Resource Limits Analysis ===${NC}"
    
    local pods_without_limits=$(kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | 
        select(.spec.containers[] | (.resources.limits.memory // .resources.limits.cpu) == null) |
        "\(.metadata.namespace)/\(.metadata.name)"')
    
    if [[ -n "$pods_without_limits" ]]; then
        echo -e "${YELLOW}Pods without resource limits:${NC}"
        echo "$pods_without_limits" | head -10
        log "WARN" "Pods without resource limits detected"
    else
        echo -e "${GREEN}All pods have resource limits defined${NC}"
    fi
}

# Comprehensive security scan
security_scan() {
    if [[ "$(get_config 'security_checks')" != "true" ]]; then
        log "INFO" "Security checks disabled in configuration"
        return 0
    fi
    
    log "INFO" "Starting comprehensive security scan..."
    
    # Get individual security check settings
    local check_privileged=$(get_config 'security.check_privileged_pods')
    local check_hostpath=$(get_config 'security.check_hostpath_mounts')
    local check_rbac=$(get_config 'security.check_rbac')
    local check_network_policies=$(get_config 'security.check_network_policies')
    
    # Run enabled security checks
    if [[ "$check_privileged" != "false" ]]; then
        check_privileged_pods
        check_root_users
        check_capabilities
    fi
    
    if [[ "$check_hostpath" != "false" ]]; then
        check_hostpath_mounts
        check_host_network
    fi
    
    if [[ "$check_rbac" != "false" ]]; then
        check_rbac_configuration
        check_service_account_tokens
    fi
    
    if [[ "$check_network_policies" != "false" ]]; then
        check_network_policies
    fi
    
    # Additional security checks
    check_pod_security_standards
    check_image_security
    check_resource_limits
    
    log "INFO" "Security scan completed"
    
    # Generate security summary
    echo -e "\n${CYAN}=== Security Scan Summary ===${NC}"
    echo "Security scan completed. Check the log file for detailed warnings and recommendations."
    echo "Log file: $LOG_FILE"
}