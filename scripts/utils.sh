#!/bin/bash

#==============================================================================
# Utility Functions Module
# Common utilities, logging, and helper functions
#==============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        "ERROR")   echo -e "${RED}[ERROR]${NC} $message" ;;
        "WARN")    echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "INFO")    echo -e "${GREEN}[INFO]${NC} $message" ;;
        "DEBUG")   echo -e "${BLUE}[DEBUG]${NC} $message" ;;
        *)         echo "$message" ;;
    esac
}

# Check prerequisites
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        log "INFO" "Please install missing tools and try again"
        exit 1
    fi
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log "ERROR" "Cannot connect to Kubernetes cluster"
        log "INFO" "Please check your kubeconfig and cluster connectivity"
        exit 1
    fi
    
    log "INFO" "Prerequisites check passed"
}

# Initialize script
initialize() {
    mkdir -p "$TEMP_DIR"
    trap cleanup EXIT
    
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    
    log "INFO" "=== Kubernetes Maintenance Script Started ==="
    log "INFO" "Script directory: $SCRIPT_DIR"
    log "INFO" "Temp directory: $TEMP_DIR"
    log "INFO" "Log file: $LOG_FILE"
}

# Cleanup function
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Progress indicator
show_progress() {
    local message="$1"
    echo -ne "${BLUE}[INFO]${NC} $message"
    for i in {1..3}; do
        echo -n "."
        sleep 0.5
    done
    echo " done"
}

# Confirmation prompt
confirm_action() {
    local message="$1"
    local default="${2:-N}"
    
    if [[ "$default" == "Y" ]]; then
        echo -e "\n${YELLOW}$message (Y/n)${NC}"
    else
        echo -e "\n${YELLOW}$message (y/N)${NC}"
    fi
    
    read -r confirmation
    
    if [[ "$default" == "Y" ]]; then
        [[ "$confirmation" != "n" && "$confirmation" != "N" ]]
    else
        [[ "$confirmation" == "y" || "$confirmation" == "Y" ]]
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes="$1"
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    
    while [[ $bytes -ge 1024 && $unit -lt 4 ]]; do
        bytes=$((bytes / 1024))
        unit=$((unit + 1))
    done
    
    echo "${bytes}${units[$unit]}"
}

# Check if namespace is excluded
is_namespace_excluded() {
    local namespace="$1"
    local excluded_namespaces
    excluded_namespaces=$(get_config 'excluded_namespaces' | jq -r '.[]' | tr '\n' ' ')
    
    [[ " $excluded_namespaces " =~ " $namespace " ]]
}