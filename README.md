# Kubernetes Maintenance Tool

A comprehensive, production-ready bash script for Kubernetes cluster maintenance operations. This tool provides an interactive menu system and command-line interface for common DevOps tasks including health checks, node management, log collection, resource cleanup, and security scanning.

## 🚀 Features

### Core Functionality
- **📊 Cluster Health Checks**: Automated monitoring of node status, pod distribution, and resource utilization
- **🏗️ Node Management**: Safe node operations (drain, cordon, uncordon) with confirmation prompts
- **🚀 Enhanced kubectl Shortcuts**: Predefined functions for logs, exec, port-forward with error handling
- **📜 Log Aggregation**: Automated collection from critical pods and systemd services
- **🧹 Resource Cleanup**: Cleanup of evicted pods, completed jobs, unused ConfigMaps/Secrets
- **🔒 Security Scanning**: Vulnerability checks, RBAC analysis, privilege escalation detection
- **⚙️ Interactive Menu**: User-friendly navigation with color-coded output
- **📋 Audit Logging**: Complete audit trail of all operations

### Advanced Features
- **Configurable Thresholds**: Customizable warning levels for CPU, memory, disk usage
- **Retention Policies**: Automatic cleanup based on age and usage patterns
- **Idempotent Operations**: Safe to run multiple times without side effects
- **Error Handling**: Comprehensive error checking and graceful failure handling
- **Progress Indicators**: Visual feedback for long-running operations

## 📁 Project Structure

```
k8s-maintenance.sh          # Main entry point
k8s-config.yaml            # Configuration file
lib/
├── config.sh              # Configuration management
├── utils.sh                # Utility functions and logging
├── health-checks.sh        # Cluster health monitoring
├── kubectl-shortcuts.sh    # Enhanced kubectl functions
├── node-management.sh      # Node maintenance operations
├── log-collection.sh       # Log aggregation and archival
├── resource-cleanup.sh     # Resource cleanup functions
├── security-checks.sh      # Security scanning and analysis
└── interactive-menu.sh     # User interface and navigation
```

## 🔧 Prerequisites

### Required Tools
- `kubectl` - Kubernetes command-line tool
- `jq` - JSON processor
- `yq` - YAML processor
- `bash` (version 4.0+)

### Installation Commands
```bash
# On Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y kubectl jq

# Install yq
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# On CentOS/RHEL
sudo yum install -y kubectl jq
# Install yq as above

# On macOS
brew install kubectl jq yq
```

### Kubernetes Access
- Valid kubeconfig file configured
- Appropriate RBAC permissions for cluster operations
- Network connectivity to the Kubernetes API server

## 🚀 Quick Start

1. **Clone and Setup**
   ```bash
   git clone <repository-url>
   cd k8s-maintenance
   chmod +x k8s-maintenance.sh
   ```

2. **Verify Prerequisites**
   ```bash
   ./k8s-maintenance.sh --help
   ```

3. **Interactive Mode**
   ```bash
   ./k8s-maintenance.sh
   ```

4. **Command Line Mode**
   ```bash
   ./k8s-maintenance.sh health      # Run health check
   ./k8s-maintenance.sh security    # Run security scan
   ./k8s-maintenance.sh cleanup     # Run cleanup
   ./k8s-maintenance.sh logs        # Collect logs
   ```

## 📖 Usage Guide

### Interactive Menu
The script provides an intuitive menu system with the following options:

1. **📊 Cluster Health Check**
   - Node status and resource utilization
   - Pod distribution across nodes
   - System component health
   - Storage capacity analysis

2. **🏗️ Node Management**
   - Safe node draining with confirmation
   - Cordon/uncordon operations
   - Node resource monitoring
   - Disk usage checks

3. **🚀 Pod Operations**
   - Enhanced log retrieval with filtering
   - Interactive pod execution
   - Port forwarding with cleanup
   - Namespace overview and analysis

4. **📜 Log Collection**
   - Critical pod log aggregation
   - Problematic pod log collection
   - Systemd service log gathering
   - Time-range based collection

5. **🧹 Resource Cleanup**
   - Evicted pod removal
   - Completed job cleanup
   - Unused resource identification
   - Orphaned PVC cleanup

6. **🔒 Security Scan**
   - Privileged pod detection
   - HostPath mount analysis
   - RBAC permission review
   - Image security assessment

### Command Line Interface

```bash
# Health operations
./k8s-maintenance.sh health          # Full health check
./k8s-maintenance.sh security        # Security scan

# Maintenance operations
./k8s-maintenance.sh cleanup         # Automated cleanup
./k8s-maintenance.sh logs            # Log collection
./k8s-maintenance.sh --drain NODE    # Drain specific node

# Information
./k8s-maintenance.sh --help          # Show help
./k8s-maintenance.sh --version       # Show version
```

## ⚙️ Configuration

The tool uses a YAML configuration file (`k8s-config.yaml`) for customization:

### Key Configuration Sections

```yaml
# Resource thresholds for warnings
thresholds:
  cpu_warning: 80          # CPU usage percentage
  memory_warning: 85       # Memory usage percentage
  disk_warning: 90         # Disk usage percentage

# Namespaces to exclude from operations
excluded_namespaces:
  - "kube-system"
  - "kube-public"
  - "default"

# Retention settings
retention_days: 7          # Job cleanup retention
log_lines: 1000           # Log lines to collect

# Feature toggles
security_checks: true      # Enable security scanning
auto_cleanup: false       # Require confirmation for cleanup
```

### Customization Options

- **Thresholds**: Adjust warning levels for resource usage
- **Excluded Namespaces**: Protect critical namespaces from cleanup
- **Retention Policies**: Configure how long to keep resources
- **Security Settings**: Enable/disable specific security checks
- **Log Collection**: Customize patterns and limits

## 🔒 Security Considerations

### RBAC Requirements
The script requires appropriate permissions for cluster operations:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-maintenance
rules:
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "configmaps", "secrets", "events", "persistentvolumes", "persistentvolumeclaims"]
  verbs: ["get", "list", "delete", "update"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "daemonsets"]
  verbs: ["get", "list"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "delete"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  verbs: ["get", "list"]
```

### Safety Features
- **Confirmation Prompts**: Critical operations require explicit confirmation
- **Excluded Namespaces**: System namespaces protected by default
- **Dry-run Mode**: Preview operations before execution
- **Audit Logging**: Complete operation history for compliance

## 📊 Monitoring and Logging

### Audit Trail
All operations are logged with timestamps to `k8s-maintenance.log`:

```
[2025-06-11 10:30:15] [INFO] === Kubernetes Maintenance Script Started ===
[2025-06-11 10:30:16] [INFO] Prerequisites check passed
[2025-06-11 10:30:17] [INFO] Starting comprehensive cluster health check...
[2025-06-11 10:30:20] [WARN] Node worker-1 CPU usage high: 85%
[2025-06-11 10:30:25] [INFO] Cluster health check completed
```

### Log Levels
- **INFO**: General operational information
- **WARN**: Warning conditions requiring attention
- **ERROR**: Error conditions that prevent operation completion
- **DEBUG**: Detailed debugging information

## 🚨 Troubleshooting

### Common Issues

1. **Permission Denied**
   ```bash
   # Solution: Check RBAC permissions
   kubectl auth can-i --list
   ```

2. **Connection Refused**
   ```bash
   # Solution: Verify kubeconfig
   kubectl cluster-info
   ```

3. **Metrics Unavailable**
   ```bash
   # Solution: Install metrics server
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

4. **Configuration Errors**
   ```bash
   # Solution: Validate YAML syntax
   yq eval k8s-config.yaml
   ```

### Debug Mode
Enable verbose logging by setting environment variable:
```bash
export K8S_MAINTENANCE_DEBUG=true
./k8s-maintenance.sh
```

## 🔧 Advanced Usage

### Custom Scripts Integration
The modular design allows easy extension:

```bash
# Source specific modules in your scripts
source /path/to/k8s-maintenance/lib/utils.sh
source /path/to/k8s-maintenance/lib/health-checks.sh

# Use functions in your automation
check_node_status
cleanup_evicted_pods true
```

### Automation Examples

```bash
# Daily health check (cron job)
0 9 * * * /path/to/k8s-maintenance.sh health > /var/log/k8s-health.log 2>&1

# Weekly cleanup
0 2 * * 0 /path/to/k8s-maintenance.sh cleanup

# Security scan integration
./k8s-maintenance.sh security | grep -E "(WARN|ERROR)" | mail -s "K8s Security Report" admin@company.com
```

## 🤝 Contributing

### Development Setup
1. Fork the repository
2. Create a feature branch
3. Follow bash best practices
4. Add comprehensive error handling
5. Update documentation
6. Test thoroughly

### Code Standards
- Use `set -euo pipefail` for safety
- Implement proper error handling
- Add detailed logging
- Follow consistent naming conventions
- Include comprehensive comments

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- Kubernetes community for excellent documentation
- DevOps engineers who inspired best practices
- Contributors to jq, yq, and other essential tools

## 📞 Support

For issues, questions, or contributions:
- Create an issue in the repository
- Review the troubleshooting section
- Check the audit logs for detailed error information

---

**Version**: 1.0.0  
**Last Updated**: June 11, 2025  
**Compatibility**: Kubernetes 1.20+, Bash 4.0+