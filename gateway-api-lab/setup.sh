#!/bin/bash
# =============================================================================
# Kubernetes Gateway API Lab - Automated Setup Script
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
# 1. Creates a 3-node Kubernetes cluster using KIND (Docker containers)
# 2. Installs Cilium as the network fabric (CNI)
# 3. Provides external IPs via the chosen LB_PROVIDER (metallb | cilium)
# 4. Installs Gateway API CRDs (the standard definitions)
# 5. Installs Envoy Gateway (the actual load balancer implementation)
# 6. Creates a TLS certificate and Gateway resource
# 7. Deploys a sample web application
# 8. Configures routing (HTTPRoute)
#
# PREREQUISITES:
# - Docker Desktop or Docker Engine (running)
# - kubectl (Kubernetes CLI)
# - kind (Kubernetes IN Docker)
# - helm (Package manager for K8s)
# - cilium CLI
#
# Works on: macOS (Intel/Apple Silicon) and Linux
#
# =============================================================================

set -e  # Exit on any error

# Colors for output (makes logs easier to read)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Version Configuration
# All pinned versions live in versions.env (single source of truth, shared
# across labs). Source it relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

CLUSTER_NAME="gateway-api-lab"

# LoadBalancer provider for the Gateway's external IP: metallb | cilium
#   metallb -> installs MetalLB (separate controller)            [default]
#   cilium  -> uses Cilium's built-in LB-IPAM + L2 announcements (no extra pods)
LB_PROVIDER="${LB_PROVIDER:-metallb}"

# Set INSTALL_AGENTGATEWAY=false to skip the AI-gateway step
INSTALL_AGENTGATEWAY="${INSTALL_AGENTGATEWAY:-true}"

# Helper functions for formatted output
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# Step 1: Check Prerequisites
# =============================================================================
check_prerequisites() {
    info "Checking prerequisites..."

    # Verify all required tools are installed
    command -v docker >/dev/null 2>&1 || error "Docker is required but not installed."
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not installed."
    command -v kind >/dev/null 2>&1 || error "kind is required but not installed."
    command -v helm >/dev/null 2>&1 || error "helm is required but not installed."
    command -v cilium >/dev/null 2>&1 || error "cilium CLI is required but not installed."
    command -v openssl >/dev/null 2>&1 || error "openssl is required but not installed."

    # Check Docker daemon is running
    docker info >/dev/null 2>&1 || error "Docker is not running. Please start Docker."

    success "All prerequisites met!"
}

# =============================================================================
# Step 2: Create KIND Cluster
# Creates a 3-node cluster (1 control-plane + 2 workers) in Docker
# Think of this as provisioning 3 virtual servers
# =============================================================================
create_cluster() {
    info "Creating KIND cluster: $CLUSTER_NAME"
    info "This creates 3 Docker containers that act as Kubernetes nodes"

    # Remove existing cluster if present (clean slate)
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "Cluster $CLUSTER_NAME already exists. Deleting..."
        kind delete cluster --name $CLUSTER_NAME
    fi

    # Create cluster from config file. --image makes versions.env authoritative
    # for the Kubernetes version (overrides the inline image in the config).
    kind create cluster --config=01-kind-config.yaml --image "$K8S_NODE_IMAGE"
    success "KIND cluster created (Kubernetes $K8S_NODE_IMAGE)!"
}

# =============================================================================
# Step 3: Install Cilium CNI
# Cilium provides pod networking using eBPF (faster than iptables)
# Think of it as the "network switches" connecting your pods
# =============================================================================
install_cilium() {
    info "Installing Cilium CNI v$CILIUM_VERSION..."
    info "Cilium will handle all networking between pods (containers)"

    # When using Cilium as the LoadBalancer, enable L2 announcements + a higher
    # k8s client rate limit (L2 leases poll the API). Not needed for MetalLB.
    local lb_flags=()
    if [ "$LB_PROVIDER" = "cilium" ]; then
        info "LB_PROVIDER=cilium -> enabling L2 announcements + LB-IPAM"
        lb_flags=(
            --set l2announcements.enabled=true
            --set externalIPs.enabled=true
            --set k8sClientRateLimit.qps=50
            --set k8sClientRateLimit.burst=100
        )
    fi

    cilium install \
        --version $CILIUM_VERSION \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost=${CLUSTER_NAME}-control-plane \
        --set k8sServicePort=6443 \
        "${lb_flags[@]}"

    info "Waiting for Cilium to be ready (this may take 1-2 minutes)..."
    cilium status --wait

    success "Cilium installed!"
}

# =============================================================================
# Step 4: Install MetalLB
# MetalLB provides LoadBalancer IPs in environments without cloud provider
# Think of it as your "IP address pool" for virtual IPs
# =============================================================================
install_metallb() {
    info "Installing MetalLB $METALLB_VERSION..."
    info "MetalLB will assign external IPs to LoadBalancer services"

    # Install MetalLB components
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml

    info "Waiting for MetalLB pods to be ready..."
    kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=120s

    # Auto-detect KIND network and configure IP pool
    info "Configuring MetalLB IP pool based on Docker network..."

    # Get the Docker network subnet used by KIND
    # NOTE: On macOS (Docker Desktop), the 'kind' network often has BOTH an IPv4
    # and an IPv6 subnet. The Go template's {{range}} concatenates them with no
    # separator, producing garbage like "fc00:f853:ccd:e793::/64172.19.0.0/16".
    # We insert a newline between entries and grep for the IPv4 CIDR explicitly.
    KIND_NET_CIDR=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
        | head -1)

    if [ -z "$KIND_NET_CIDR" ]; then
        error "Could not determine IPv4 subnet of the Docker 'kind' network."
    fi

    KIND_NET_PREFIX=$(echo "$KIND_NET_CIDR" | cut -d. -f1-2)

    info "Detected KIND network (IPv4): $KIND_NET_CIDR"
    info "Using IP range: ${KIND_NET_PREFIX}.255.200-${KIND_NET_PREFIX}.255.250"

    # Create MetalLB config with dynamic IP range
    cat > /tmp/metallb-config.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${KIND_NET_PREFIX}.255.200-${KIND_NET_PREFIX}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

    kubectl apply -f /tmp/metallb-config.yaml
    rm /tmp/metallb-config.yaml

    success "MetalLB installed and configured!"
}

# =============================================================================
# Step 4 (alternative): Configure Cilium LoadBalancer (LB-IPAM + L2)
# Used when LB_PROVIDER=cilium. No extra controller — Cilium (already the CNI,
# installed with L2 flags above) just needs a CiliumLoadBalancerIPPool and a
# CiliumL2AnnouncementPolicy. API versions (Cilium 1.19): IPPool cilium.io/v2,
# L2 policy cilium.io/v2alpha1.
# =============================================================================
install_cilium_lb() {
    info "Configuring Cilium LB-IPAM + L2 announcements..."

    KIND_NET_CIDR=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
        | head -1)
    [ -z "$KIND_NET_CIDR" ] && error "Could not determine IPv4 subnet of the Docker 'kind' network."
    KIND_NET_PREFIX=$(echo "$KIND_NET_CIDR" | cut -d. -f1-2)

    info "Detected KIND network (IPv4): $KIND_NET_CIDR"
    info "Using IP range: ${KIND_NET_PREFIX}.255.200-${KIND_NET_PREFIX}.255.250"

    cat > /tmp/cilium-lb.yaml <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: kind-pool
spec:
  blocks:
    - start: "${KIND_NET_PREFIX}.255.200"
      stop: "${KIND_NET_PREFIX}.255.250"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: kind-l2
spec:
  interfaces:
    - ^eth[0-9]+
  externalIPs: true
  loadBalancerIPs: true
EOF

    kubectl apply -f /tmp/cilium-lb.yaml
    rm /tmp/cilium-lb.yaml

    success "Cilium LB-IPAM + L2 announcements configured!"
}

# =============================================================================
# Step 4 dispatcher: install the chosen LoadBalancer
# =============================================================================
install_loadbalancer() {
    case "$LB_PROVIDER" in
        metallb) install_metallb ;;
        cilium)  install_cilium_lb ;;
        *) error "Unknown LB_PROVIDER='$LB_PROVIDER' (use 'metallb' or 'cilium')." ;;
    esac
}

# =============================================================================
# Step 5: Install Gateway API CRDs (Experimental Channel)
# CRDs = Custom Resource Definitions (new types of K8s objects)
# This adds GatewayClass, Gateway, HTTPRoute, TLSRoute, TCPRoute, etc.
#
# We use EXPERIMENTAL channel to get TLSRoute (for TLS passthrough)
# Standard channel only has: GatewayClass, Gateway, HTTPRoute, GRPCRoute
# Experimental adds: TLSRoute, TCPRoute, UDPRoute, ReferenceGrant
# =============================================================================
install_gateway_api_crds() {
    info "Installing Gateway API CRDs $GATEWAY_API_VERSION (Experimental Channel)..."
    info "This includes TLSRoute for TLS passthrough routing"

    # Use --server-side for large CRD manifests (avoids annotation size limits)
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml

    success "Gateway API CRDs installed (including TLSRoute)!"
}

# =============================================================================
# Step 6: Install Envoy Gateway
# Envoy Gateway is the controller that implements the Gateway API
# It watches for Gateway/HTTPRoute resources and configures Envoy proxies
# =============================================================================
install_envoy_gateway() {
    info "Installing Envoy Gateway $ENVOY_GATEWAY_VERSION..."
    info "Envoy Gateway watches your configs and manages Envoy proxies"

    # Install via Helm, skip CRDs since we installed them in Step 5
    helm install eg oci://docker.io/envoyproxy/gateway-helm \
        --version $ENVOY_GATEWAY_VERSION \
        -n envoy-gateway-system \
        --create-namespace \
        --skip-crds

    info "Waiting for Envoy Gateway controller to be ready..."
    kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

    # Create GatewayClass (required when using --skip-crds)
    # GatewayClass = "which vendor's load balancer to use"
    info "Creating GatewayClass 'eg' for Envoy Gateway..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

    # Wait for GatewayClass to be accepted by the controller
    sleep 2
    kubectl wait --timeout=60s gatewayclass/eg --for=condition=Accepted

    success "Envoy Gateway installed!"
}

# =============================================================================
# Step 7: Deploy Gateway Resource
# The Gateway is your "load balancer VIP" - it listens on ports 80 and 443
# IMPORTANT: We create the TLS certificate FIRST, then the Gateway
# =============================================================================
deploy_gateway() {
    info "Creating TLS certificate for HTTPS..."
    info "This is a self-signed cert for local testing"

    # Generate self-signed certificate
    # -x509: Create self-signed cert (no CA needed)
    # -nodes: No password on the private key
    # -days 365: Valid for 1 year
    # -subj: Certificate subject (CN = Common Name)
    # -addext: Add Subject Alternative Names (SANs) for multiple domains
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /tmp/tls.key -out /tmp/tls.crt \
        -subj "/CN=*.local.dev" \
        -addext "subjectAltName=DNS:*.local.dev,DNS:localhost" 2>/dev/null

    # Create Kubernetes Secret from the certificate
    # The Gateway will reference this secret for TLS termination
    kubectl create secret tls eg-tls-cert \
        --cert=/tmp/tls.crt \
        --key=/tmp/tls.key \
        -n envoy-gateway-system 2>/dev/null || true

    # Clean up temp files
    rm -f /tmp/tls.key /tmp/tls.crt

    info "Deploying Gateway resource (ports 80 and 443)..."
    kubectl apply -f 03-gateway.yaml

    info "Waiting for Gateway to get an external IP and be ready..."
    kubectl wait --timeout=5m -n envoy-gateway-system gateway/eg-gateway --for=condition=Programmed

    success "Gateway deployed!"
}

# =============================================================================
# Step 8: Deploy Sample Application
# Deploys two versions of a simple web app:
# - Stable (3 replicas): Returns "Hello from Gateway API!"
# - Canary (1 replica): Returns "CANARY VERSION!"
# =============================================================================
deploy_app() {
    info "Deploying sample web application..."
    info "Creating 'demo-app' namespace with stable and canary versions"

    kubectl apply -f 04-webapp.yaml
    kubectl apply -f 05-webapp-canary.yaml

    info "Waiting for application pods to be ready..."
    kubectl wait --timeout=120s -n demo-app deployment/webapp --for=condition=Available
    kubectl wait --timeout=120s -n demo-app deployment/webapp-canary --for=condition=Available

    success "Sample application deployed!"
}

# =============================================================================
# Step 9: Deploy HTTPRoute
# HTTPRoute connects the Gateway to the application
# It defines: "requests to webapp.local.dev go to webapp-service"
# =============================================================================
deploy_httproute() {
    info "Deploying HTTPRoute (routing rules)..."
    info "This tells the Gateway where to send incoming requests"

    kubectl apply -f 06-httproute-basic.yaml

    success "HTTPRoute deployed!"
}

# =============================================================================
# Step 9b (optional): Install Agentgateway + Microsoft Learn MCP
#
# Agentgateway is a SEPARATE gateway from Envoy Gateway, built specifically
# for AI/agent traffic (MCP, A2A protocols). It has its own GatewayClass
# 'agentgateway' (auto-created by the chart) and its own control plane.
# It can coexist with Envoy Gateway in the same cluster.
#
# Note: as of agentgateway v1.0 the project was decoupled from kgateway.
# Charts now live at cr.agentgateway.dev/charts/ (not ghcr.io/kgateway-dev).
#
# This step installs the agentgateway control plane, creates an agentgateway
# proxy Gateway, wires the public Microsoft Learn MCP server
# (https://learn.microsoft.com/api/mcp) as an AgentgatewayBackend, and
# exposes it on the proxy at the path /mcp-mslearn.
#
# Microsoft Learn MCP is a public, anonymous streamable-HTTP MCP server
# that exposes Microsoft documentation tools (search, fetch, code samples).
# No API key is required.
# =============================================================================
install_agentgateway() {
    if [ "$INSTALL_AGENTGATEWAY" != "true" ]; then
        info "Skipping agentgateway install (INSTALL_AGENTGATEWAY=$INSTALL_AGENTGATEWAY)"
        return
    fi

    info "Installing agentgateway $AGENTGATEWAY_VERSION..."
    info "This adds an AI gateway alongside Envoy Gateway for MCP traffic"

    # 1. CRDs first (creates the agentgateway-system namespace)
    helm upgrade -i agentgateway-crds \
        oci://cr.agentgateway.dev/charts/agentgateway-crds \
        --create-namespace --namespace agentgateway-system \
        --version "$AGENTGATEWAY_VERSION"

    # 2. Control plane
    helm upgrade -i agentgateway \
        oci://cr.agentgateway.dev/charts/agentgateway \
        --namespace agentgateway-system \
        --version "$AGENTGATEWAY_VERSION"

    info "Waiting for agentgateway controller to be Available..."
    kubectl wait --timeout=5m -n agentgateway-system \
        --for=condition=Available deployment/agentgateway 2>/dev/null || \
    kubectl wait --timeout=2m -n agentgateway-system \
        --for=condition=Available deployment \
        -l app.kubernetes.io/name=agentgateway 2>/dev/null || \
    sleep 5

    # The chart auto-creates the GatewayClass named 'agentgateway' with
    # controllerName agentgateway.dev/agentgateway. Wait until it's accepted.
    kubectl wait --timeout=60s gatewayclass/agentgateway --for=condition=Accepted 2>/dev/null || true

    # 3. Create the agentgateway proxy (Gateway resource)
    info "Creating agentgateway proxy Gateway (10-agentgateway.yaml)..."
    kubectl apply -f 10-agentgateway.yaml

    info "Waiting for agentgateway-proxy Gateway to be Programmed..."
    kubectl wait --timeout=5m -n agentgateway-system \
        gateway/agentgateway-proxy --for=condition=Programmed

    # 4. AgentgatewayBackend + HTTPRoute for Microsoft Learn MCP
    info "Wiring Microsoft Learn MCP at /mcp-mslearn (11-mcp-mslearn.yaml)..."
    kubectl apply -f 11-mcp-mslearn.yaml

    success "Agentgateway installed with Microsoft Learn MCP backend at /mcp-mslearn"
}

# =============================================================================
# Step 10: Configure /etc/hosts
# Maps the Gateway IP to human-readable hostnames
# This lets you use: curl http://webapp.local.dev/
# =============================================================================
configure_hosts() {
    info "Configuring /etc/hosts for local testing..."

    # Get the Gateway's external IP (assigned by MetalLB)
    GATEWAY_IP=$(kubectl get gateway/eg-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')

    if [ -z "$GATEWAY_IP" ]; then
        warn "Could not get Gateway IP. You may need to configure /etc/hosts manually."
        return
    fi

    # macOS-specific: Docker Desktop runs containers in a Linux VM, so the
    # MetalLB IPs (172.x.x.x on the 'kind' Docker network) are NOT routable
    # from the macOS host. Map the hostnames to 127.0.0.1 instead and rely on
    # `kubectl port-forward` (see print_status) to actually reach the gateway.
    if [ "$(uname -s)" = "Darwin" ]; then
        HOSTS_TARGET="127.0.0.1"
        info "macOS detected — pointing hostnames at 127.0.0.1 (use kubectl port-forward to test)"
    else
        HOSTS_TARGET="$GATEWAY_IP"
    fi

    # Check if entries already exist
    if grep -q "webapp.local.dev" /etc/hosts; then
        warn "Host entries already exist. Skipping..."
    else
        echo "Adding entries to /etc/hosts (requires sudo)..."
        echo "$HOSTS_TARGET webapp.local.dev api.local.dev" | sudo tee -a /etc/hosts
    fi

    success "Hosts configured!"
}

# =============================================================================
# Final Status Output
# Shows what was created and how to test it
# =============================================================================
print_status() {
    echo ""
    echo "=============================================="
    echo -e "${GREEN}Gateway API Lab Setup Complete!${NC}"
    echo "=============================================="
    echo ""

    GATEWAY_IP=$(kubectl get gateway/eg-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)

    echo "Gateway IP (inside Docker 'kind' network): $GATEWAY_IP"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Commands:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$(uname -s)" = "Darwin" ]; then
        # macOS: MetalLB IPs (172.x.x.x) are inside Docker Desktop's Linux VM
        # and not routable from the Mac host. Use port-forward instead.
        cat <<EOF
  # macOS NOTE: the Gateway IP ($GATEWAY_IP) is NOT reachable from your Mac
  # because Docker Desktop runs containers inside a Linux VM.
  # Use ONE of the following approaches to test:

  # Option 1 — kubectl port-forward (recommended, terminal stays busy):
  #   In terminal A:
  #     SVC=\$(kubectl -n envoy-gateway-system get svc \\
  #       -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway \\
  #       -o jsonpath='{.items[0].metadata.name}')
  #     kubectl -n envoy-gateway-system port-forward svc/\$SVC 8080:80 8443:443
  #   In terminal B:
  #     curl -H 'Host: webapp.local.dev' http://localhost:8080/
  #     curl -k -H 'Host: webapp.local.dev' https://localhost:8443/

  # Option 2 — docker exec from inside a kind node (no port-forward needed):
  #   docker exec ${CLUSTER_NAME}-control-plane \\
  #     curl -s -H 'Host: webapp.local.dev' http://$GATEWAY_IP/

  # Option 3 — Hostname via /etc/hosts entry (works once /etc/hosts maps
  # webapp.local.dev to 127.0.0.1 AND a port-forward on :80/:443 is active):
  #   curl http://webapp.local.dev/
  #   curl -k https://webapp.local.dev/
EOF
    else
        cat <<EOF
  # HTTP test (if /etc/hosts configured):
  curl http://webapp.local.dev/

  # HTTP test (using Host header):
  curl -H 'Host: webapp.local.dev' http://$GATEWAY_IP/

  # HTTPS test (self-signed cert, use -k to skip verification):
  curl -k https://webapp.local.dev/
EOF
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "View Resources:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  kubectl get gatewayclass,gateway,httproute -A"
    echo "  kubectl get pods -n envoy-gateway-system"
    echo "  kubectl get pods -n demo-app"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Advanced Routing Examples:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  # Traffic splitting (90% stable, 10% canary):"
    echo "  kubectl apply -f 07-httproute-canary.yaml"
    echo ""
    echo "  # Header-based routing (X-Canary: true → canary):"
    echo "  kubectl apply -f 08-httproute-header.yaml"
    echo ""

    if [ "$INSTALL_AGENTGATEWAY" = "true" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Agentgateway (Microsoft Learn MCP + OpenAI LLM):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  # Port convention: Envoy webapp uses 8080/8443, agentgateway uses 8081"
        echo "  # (two separate gateways — keep them on different local ports)."
        echo "  # Both macOS and Linux: port-forward the agentgateway proxy"
        echo "  kubectl -n agentgateway-system port-forward \\"
        echo "    deployment/agentgateway-proxy 8081:80"
        echo ""
        echo "  # (Optional) route the agent's LLM calls through agentgateway too:"
        echo "  # store your key in a Secret (the gateway injects it) and apply the"
        echo "  # OpenAI backend + route."
        echo "  kubectl create secret generic openai-secret -n agentgateway-system \\"
        echo "    --from-literal=Authorization=\"Bearer \$OPENAI_API_KEY\""
        echo "  kubectl apply -f 12-llm-openai.yaml"
        echo ""
        echo "  # In another terminal, run the OpenAI Agents SDK test client. It"
        echo "  # routes BOTH MCP tools and LLM inference through agentgateway; with"
        echo "  # the Secret above no OPENAI_API_KEY export is needed for the run:"
        echo "  pip install --upgrade openai-agents"
        echo "  python3 test-mslearn-agent.py"
        echo ""
        echo "  # Or poke the MCP endpoint with curl (just confirms reachability;"
        echo "  # MCP needs a JSON-RPC client for anything useful):"
        echo "  curl -i http://localhost:8081/mcp-mslearn"
        echo ""
    fi
}

# =============================================================================
# Main Execution
# Runs all steps in order
# =============================================================================
main() {
    echo "=============================================="
    echo "Kubernetes Gateway API Lab Setup"
    echo "=============================================="
    echo ""
    echo "This script will create a complete Gateway API lab environment."
    echo "Estimated time: 5-10 minutes"
    echo ""

    check_prerequisites
    create_cluster
    install_cilium
    install_loadbalancer
    install_gateway_api_crds
    install_envoy_gateway
    deploy_gateway
    deploy_app
    deploy_httproute
    install_agentgateway
    configure_hosts
    print_status
}

# Run main function
main "$@"
