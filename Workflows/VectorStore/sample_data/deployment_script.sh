#!/bin/bash

################################################################################
# CloudSync Pro Deployment Script
# Version: 3.2.1
# Description: Automated deployment script for CloudSync Pro application
# Author: DevOps Team - TechVision Solutions
################################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable

# Configuration
APP_NAME="cloudsync-pro"
APP_VERSION="3.2.1"
DEPLOYMENT_ENV=${1:-production}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/var/log/deployments/${APP_NAME}_${TIMESTAMP}.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

################################################################################
# Functions
################################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        log_error "Please run as root or with sudo"
        exit 1
    fi
    
    # Check required commands
    for cmd in docker kubectl helm aws; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is not installed"
            exit 1
        fi
    done
    
    log_info "All prerequisites met"
}

backup_current_deployment() {
    log_info "Creating backup of current deployment..."
    
    BACKUP_DIR="/backups/${APP_NAME}/${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"
    
    # Backup configuration
    kubectl get deployment ${APP_NAME} -o yaml > "${BACKUP_DIR}/deployment.yaml"
    kubectl get service ${APP_NAME} -o yaml > "${BACKUP_DIR}/service.yaml"
    kubectl get configmap ${APP_NAME}-config -o yaml > "${BACKUP_DIR}/configmap.yaml"
    
    log_info "Backup created at: $BACKUP_DIR"
}

pull_docker_image() {
    log_info "Pulling Docker image: ${APP_NAME}:${APP_VERSION}..."
    
    docker pull techvision/${APP_NAME}:${APP_VERSION}
    
    if [ $? -eq 0 ]; then
        log_info "Docker image pulled successfully"
    else
        log_error "Failed to pull Docker image"
        exit 1
    fi
}

update_configuration() {
    log_info "Updating application configuration..."
    
    # Update ConfigMap
    kubectl create configmap ${APP_NAME}-config \
        --from-file=config.json=/configs/${DEPLOYMENT_ENV}/config.json \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "Configuration updated"
}

deploy_application() {
    log_info "Deploying application to ${DEPLOYMENT_ENV}..."
    
    # Use Helm for deployment
    helm upgrade --install ${APP_NAME} ./helm/${APP_NAME} \
        --set image.tag=${APP_VERSION} \
        --set environment=${DEPLOYMENT_ENV} \
        --namespace=${DEPLOYMENT_ENV} \
        --wait \
        --timeout=10m
    
    if [ $? -eq 0 ]; then
        log_info "Application deployed successfully"
    else
        log_error "Deployment failed"
        rollback_deployment
        exit 1
    fi
}

run_health_checks() {
    log_info "Running health checks..."
    
    sleep 30  # Wait for pods to start
    
    # Check pod status
    READY_PODS=$(kubectl get pods -n ${DEPLOYMENT_ENV} -l app=${APP_NAME} -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -o True | wc -l)
    TOTAL_PODS=$(kubectl get pods -n ${DEPLOYMENT_ENV} -l app=${APP_NAME} --no-headers | wc -l)
    
    if [ "$READY_PODS" -eq "$TOTAL_PODS" ] && [ "$TOTAL_PODS" -gt 0 ]; then
        log_info "All $TOTAL_PODS pods are healthy"
    else
        log_error "Only $READY_PODS out of $TOTAL_PODS pods are ready"
        rollback_deployment
        exit 1
    fi
    
    # Test API endpoint
    API_URL="https://api.${DEPLOYMENT_ENV}.techvision-solutions.com/health"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL")
    
    if [ "$HTTP_STATUS" -eq 200 ]; then
        log_info "API health check passed (HTTP $HTTP_STATUS)"
    else
        log_error "API health check failed (HTTP $HTTP_STATUS)"
        rollback_deployment
        exit 1
    fi
}

rollback_deployment() {
    log_warn "Initiating rollback..."
    helm rollback ${APP_NAME} -n ${DEPLOYMENT_ENV}
    log_warn "Rollback completed"
}

send_notification() {
    local status=$1
    local message=$2
    
    # Send Slack notification
    curl -X POST https://hooks.slack.com/services/YOUR_WEBHOOK \
        -H 'Content-Type: application/json' \
        -d "{\"text\":\"Deployment ${status}: ${APP_NAME} v${APP_VERSION} to ${DEPLOYMENT_ENV} - ${message}\"}"
}

################################################################################
# Main Execution
################################################################################

main() {
    log_info "Starting deployment of ${APP_NAME} v${APP_VERSION} to ${DEPLOYMENT_ENV}"
    
    check_prerequisites
    backup_current_deployment
    pull_docker_image
    update_configuration
    deploy_application
    run_health_checks
    
    log_info "Deployment completed successfully!"
    send_notification "SUCCESS" "All checks passed"
}

# Execute main function
main

exit 0
