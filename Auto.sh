#!/bin/bash

# Docker Swarm Setup Script for Raspberry Pi Cluster
# Usage: ./setup_docker_swarm.sh [init-manager|join-manager|join-worker|deploy-services|status]
# 
# Architecture:
# - rpi1 (192.168.188.52): Swarm Manager + HA LB Master (keepalived, haproxy, nginx, nodejs)
# - rpi2 (192.168.188.39): Swarm Manager + HA LB Backup (keepalived, haproxy, nginx, nodejs)  
# - rpi3 (192.168.188.33): Swarm Worker (nginx, nodejs)
# - rpi4 (192.168.188.41): Swarm Worker (nginx, nodejs)

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MANAGER_IP="192.168.188.52"  # rpi1
BACKUP_MANAGER_IP="192.168.188.39"  # rpi2
VIP="192.168.188.200"
SWARM_TOKEN_FILE="/tmp/swarm-tokens.txt"

# Node configurations
declare -A NODE_IPS=(
    ["rpi1"]="192.168.188.52"
    ["rpi2"]="192.168.188.39"
    ["rpi3"]="192.168.188.33"
    ["rpi4"]="192.168.188.41"
)

declare -A NODE_ROLES=(
    ["rpi1"]="manager"
    ["rpi2"]="manager"
    ["rpi3"]="worker"
    ["rpi4"]="worker"
)

declare -A NODE_SERVICES=(
    ["rpi1"]="keepalived,haproxy,nginx,nodejs"
    ["rpi2"]="keepalived,haproxy,nginx,nodejs"
    ["rpi3"]="nginx,nodejs"
    ["rpi4"]="nginx,nodejs"
)

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Detect current node
detect_node() {
    local current_ip=$(hostname -I | awk '{print $1}')
    
    for node in "${!NODE_IPS[@]}"; do
        if [[ "${NODE_IPS[$node]}" == "$current_ip" ]]; then
            CURRENT_NODE="$node"
            CURRENT_IP="$current_ip"
            CURRENT_ROLE="${NODE_ROLES[$node]}"
            CURRENT_SERVICES="${NODE_SERVICES[$node]}"
            break
        fi
    done
    
    if [[ -z "$CURRENT_NODE" ]]; then
        error "Unable to detect current node. Current IP: $current_ip"
        error "Expected IPs: ${NODE_IPS[*]}"
        exit 1
    fi
    
    info "Detected node: $CURRENT_NODE ($CURRENT_IP) - Role: $CURRENT_ROLE"
}

# Install Docker if not present
install_docker() {
    if command -v docker &> /dev/null; then
        info "Docker is already installed"
        return
    fi
    
    log "Installing Docker..."
    
    # Update package index
    apt update
    
    # Install required packages
    apt install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add current user to docker group (if not root)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log "Added $SUDO_USER to docker group"
    fi
    
    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    log "Docker installation completed"
}

# Initialize Docker Swarm (run on rpi1)
init_swarm_manager() {
    log "Initializing Docker Swarm on manager node..."
    
    if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active; then
        warning "Docker Swarm is already initialized"
        return
    fi
    
    # Initialize swarm
    docker swarm init --advertise-addr "$CURRENT_IP"
    
    # Get join tokens
    MANAGER_TOKEN=$(docker swarm join-token manager -q)
    WORKER_TOKEN=$(docker swarm join-token worker -q)
    
    # Save tokens to file for other nodes
    cat > "$SWARM_TOKEN_FILE" << EOF
MANAGER_TOKEN=$MANAGER_TOKEN
WORKER_TOKEN=$WORKER_TOKEN
MANAGER_IP=$CURRENT_IP
EOF
    
    log "Docker Swarm initialized successfully"
    info "Manager join token: $MANAGER_TOKEN"
    info "Worker join token: $WORKER_TOKEN"
    
    # Display join commands for other nodes
    echo
    info "=== Join Commands for Other Nodes ==="
    info "For rpi2 (manager): docker swarm join --token $MANAGER_TOKEN $CURRENT_IP:2377"
    info "For rpi3 (worker): docker swarm join --token $WORKER_TOKEN $CURRENT_IP:2377"
    info "For rpi4 (worker): docker swarm join --token $WORKER_TOKEN $CURRENT_IP:2377"
    echo
}

# Join as manager (run on rpi2)
join_swarm_manager() {
    log "Joining Docker Swarm as manager node..."
    
    if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active; then
        warning "This node is already part of a Docker Swarm"
        return
    fi
    
    if [[ ! -f "$SWARM_TOKEN_FILE" ]]; then
        error "Swarm token file not found. Please provide manager token manually."
        read -p "Enter manager join token: " MANAGER_TOKEN
        read -p "Enter manager IP: " MANAGER_IP
    else
        source "$SWARM_TOKEN_FILE"
    fi
    
    docker swarm join --token "$MANAGER_TOKEN" "$MANAGER_IP:2377"
    log "Successfully joined swarm as manager"
}

# Join as worker (run on rpi3, rpi4)
join_swarm_worker() {
    log "Joining Docker Swarm as worker node..."
    
    if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active; then
        warning "This node is already part of a Docker Swarm"
        return
    fi
    
    if [[ ! -f "$SWARM_TOKEN_FILE" ]]; then
        error "Swarm token file not found. Please provide worker token manually."
        read -p "Enter worker join token: " WORKER_TOKEN
        read -p "Enter manager IP: " MANAGER_IP
    else
        source "$SWARM_TOKEN_FILE"
    fi
    
    docker swarm join --token "$WORKER_TOKEN" "$MANAGER_IP:2377"
    log "Successfully joined swarm as worker"
}

# Create Docker Compose files for services
create_docker_compose_files() {
    log "Creating Docker Compose files..."
    
    mkdir -p /opt/swarm-services
    
    # HAProxy + Keepalived service (for rpi1 and rpi2)
    cat > /opt/swarm-services/haproxy-keepalived.yml << 'EOF'
version: '3.8'

services:
  haproxy:
    image: haproxy:2.8-alpine
    ports:
      - "80:80"
      - "8404:8404"
    volumes:
      - /opt/swarm-services/configs/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - loadbalancer
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.haproxy == true
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8404/stats"]
      interval: 30s
      timeout: 10s
      retries: 3

  keepalived:
    image: osixia/keepalived:2.0.20
    cap_add:
      - NET_ADMIN
      - NET_BROADCAST
      - NET_RAW
    network_mode: host
    volumes:
      - /opt/swarm-services/configs/keepalived.conf:/container/service/keepalived/assets/keepalived.conf:ro
    environment:
      - KEEPALIVED_INTERFACE=eth0
      - KEEPALIVED_VIRTUAL_IPS=192.168.188.200
      - KEEPALIVED_UNICAST_PEERS=#PYTHON2BASH:['192.168.188.52', '192.168.188.39']
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.keepalived == true
      restart_policy:
        condition: on-failure

networks:
  loadbalancer:
    driver: overlay
    attachable: true
EOF

    # Nginx + Node.js service (for all nodes)
    cat > /opt/swarm-services/web-services.yml << 'EOF'
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - /opt/swarm-services/configs/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /opt/swarm-services/web-content:/usr/share/nginx/html:ro
    networks:
      - webservices
    deploy:
      replicas: 4
      placement:
        constraints:
          - node.labels.web == true
      restart_policy:
        condition: on-failure
      update_config:
        parallelism: 1
        delay: 10s
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3

  nodejs-app:
    image: node:18-alpine
    ports:
      - "3000:3000"
    working_dir: /app
    volumes:
      - /opt/swarm-services/nodejs-app:/app:ro
    command: ["node", "app.js"]
    networks:
      - webservices
    deploy:
      replicas: 4
      placement:
        constraints:
          - node.labels.web == true
      restart_policy:
        condition: on-failure
      update_config:
        parallelism: 1
        delay: 10s
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  webservices:
    driver: overlay
    attachable: true
EOF

    # Create monitoring stack
    cat > /opt/swarm-services/monitoring.yml << 'EOF'
version: '3.8'

services:
  portainer:
    image: portainer/portainer-ce:latest
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - monitoring
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure

  visualizer:
    image: dockersamples/visualizer:stable
    ports:
      - "9001:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - monitoring
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure

volumes:
  portainer_data:

networks:
  monitoring:
    driver: overlay
    attachable: true
EOF
}

# Create configuration files
create_config_files() {
    log "Creating configuration files..."
    
    mkdir -p /opt/swarm-services/configs
    mkdir -p /opt/swarm-services/web-content
    mkdir -p /opt/swarm-services/nodejs-app
    
    # HAProxy configuration
    cat > /opt/swarm-services/configs/haproxy.cfg << 'EOF'
global
    log stdout local0
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    log global
    option httplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000

frontend web_frontend
    bind *:80
    default_backend web_backend

backend web_backend
    balance roundrobin
    option httpchk GET /
    server rpi1 192.168.188.52:8080 check inter 2s rise 2 fall 3
    server rpi2 192.168.188.39:8080 check inter 2s rise 2 fall 3
    server rpi3 192.168.188.33:8080 check inter 2s rise 2 fall 3
    server rpi4 192.168.188.41:8080 check inter 2s rise 2 fall 3

listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
EOF

    # Keepalived configuration for master
    cat > /opt/swarm-services/configs/keepalived-master.conf << 'EOF'
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 110
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass swarm_ha_2024
    }
    virtual_ipaddress {
        192.168.188.200/24
    }
}
EOF

    # Keepalived configuration for backup
    cat > /opt/swarm-services/configs/keepalived-backup.conf << 'EOF'
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass swarm_ha_2024
    }
    virtual_ipaddress {
        192.168.188.200/24
    }
}
EOF

    # Nginx configuration
    cat > /opt/swarm-services/configs/nginx.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /node {
        proxy_pass http://nodejs-app:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF

    # Node.js application
    cat > /opt/swarm-services/nodejs-app/app.js << 'EOF'
const http = require('http');
const os = require('os');

const server = http.createServer((req, res) => {
    const response = {
        message: 'Hello from Node.js Docker Swarm!',
        hostname: os.hostname(),
        timestamp: new Date().toISOString(),
        url: req.url,
        method: req.method
    };
    
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(response, null, 2));
});

const PORT = 3000;
server.listen(PORT, '0.0.0.0', () => {
    console.log(`Node.js server running on port ${PORT}`);
    console.log(`Container: ${os.hostname()}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('Received SIGTERM, shutting down gracefully');
    server.close(() => {
        process.exit(0);
    });
});
EOF

    # Package.json for Node.js app
    cat > /opt/swarm-services/nodejs-app/package.json << 'EOF'
{
  "name": "swarm-nodejs-app",
  "version": "1.0.0",
  "description": "Node.js application for Docker Swarm",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "author": "Swarm Admin",
  "license": "MIT"
}
EOF

    # Web content
    cat > /opt/swarm-services/web-content/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Docker Swarm Cluster</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        .info { margin: 20px 0; }
        .status { color: green; font-weight: bold; }
        .services { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin: 20px 0; }
        .service { background: #f8f9fa; padding: 15px; border-radius: 5px; border-left: 4px solid #007bff; }
        .links { margin: 20px 0; }
        .links a { 
            display: inline-block; 
            margin: 5px 10px; 
            padding: 10px 20px; 
            background: #007bff; 
            color: white; 
            text-decoration: none; 
            border-radius: 5px; 
            transition: background 0.3s;
        }
        .links a:hover { background: #0056b3; }
        .node-info { background: #e9ecef; padding: 15px; border-radius: 5px; margin: 10px 0; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🐳 Docker Swarm Raspberry Pi Cluster</h1>
            <p class="status">High Availability Load Balancer with Container Orchestration</p>
        </div>
        
        <div class="info">
            <h2>Cluster Architecture</h2>
            <div class="services">
                <div class="service">
                    <h3>rpi1 (Manager)</h3>
                    <p>IP: 192.168.188.52</p>
                    <p>Services: Swarm Manager, HAProxy, Keepalived, Nginx, Node.js</p>
                </div>
                <div class="service">
                    <h3>rpi2 (Manager)</h3>
                    <p>IP: 192.168.188.39</p> 
                    <p>Services: Swarm Manager, HAProxy, Keepalived, Nginx, Node.js</p>
                </div>
                <div class="service">
                    <h3>rpi3 (Worker)</h3>
                    <p>IP: 192.168.188.33</p>
                    <p>Services: Swarm Worker, Nginx, Node.js</p>
                </div>
                <div class="service">
                    <h3>rpi4 (Worker)</h3>
                    <p>IP: 192.168.188.41</p>
                    <p>Services: Swarm Worker, Nginx, Node.js</p>
                </div>
            </div>
        </div>
        
        <div class="info">
            <h2>Available Services</h2>
            <div class="links">
                <a href="/node" target="_blank">Node.js API</a>
                <a href="http://192.168.188.200:8404/stats" target="_blank">HAProxy Stats</a>
                <a href="http://192.168.188.52:9000" target="_blank">Portainer</a>
                <a href="http://192.168.188.52:9001" target="_blank">Swarm Visualizer</a>
            </div>
        </div>
        
        <div class="node-info">
            <p><strong>Virtual IP:</strong> 192.168.188.200 (Managed by Keepalived)</p>
            <p><strong>Load Balancer:</strong> HAProxy distributing traffic across all nodes</p>
            <p><strong>Container Orchestration:</strong> Docker Swarm with 2 managers and 2 workers</p>
            <p><strong>Last Updated:</strong> $(date)</p>
        </div>
    </div>
</body>
</html>
EOF

    log "Configuration files created"
}

# Set node labels for service placement
set_node_labels() {
    log "Setting node labels for service placement..."
    
    # Only run on manager nodes
    if [[ "$CURRENT_ROLE" != "manager" ]]; then
        warning "Node labels can only be set from manager nodes"
        return
    fi
    
    # Set labels for each node based on their role
    for node in "${!NODE_IPS[@]}"; do
        local node_ip="${NODE_IPS[$node]}"
        local services="${NODE_SERVICES[$node]}"
        
        # Get Docker node ID
        local node_id=$(docker node ls --format "{{.ID}} {{.Hostname}}" | grep "$node" | awk '{print $1}')
        
        if [[ -z "$node_id" ]]; then
            warning "Could not find Docker node ID for $node, trying IP-based lookup"
            # Alternative: try to find by IP in node description
            node_id=$(docker node ls --format "{{.ID}}" --filter "name=$node")
        fi
        
        if [[ -n "$node_id" ]]; then
            info "Setting labels for $node ($node_id)"
            
            # Set web label for all nodes
            docker node update --label-add web=true "$node_id"
            
            # Set specific service labels
            if [[ "$services" == *"haproxy"* ]]; then
                docker node update --label-add haproxy=true "$node_id"
            fi
            
            if [[ "$services" == *"keepalived"* ]]; then
                docker node update --label-add keepalived=true "$node_id"
            fi
            
            # Set role-specific labels
            if [[ "${NODE_ROLES[$node]}" == "manager" ]]; then
                docker node update --label-add manager=true "$node_id"
            fi
        else
            warning "Could not set labels for $node - node not found in swarm"
        fi
    done
    
    log "Node labels configured"
}

# Deploy services to the swarm
deploy_services() {
    log "Deploying services to Docker Swarm..."
    
    # Only run on manager nodes
    if [[ "$CURRENT_ROLE" != "manager" ]]; then
        error "Services can only be deployed from manager nodes"
        exit 1
    fi
    
    # Ensure configurations are created
    create_docker_compose_files
    create_config_files
    set_node_labels
    
    # Copy appropriate keepalived config based on node
    if [[ "$CURRENT_NODE" == "rpi1" ]]; then
        cp /opt/swarm-services/configs/keepalived-master.conf /opt/swarm-services/configs/keepalived.conf
    else
        cp /opt/swarm-services/configs/keepalived-backup.conf /opt/swarm-services/configs/keepalived.conf
    fi
    
    # Deploy web services (nginx + nodejs)
    info "Deploying web services..."
    docker stack deploy -c /opt/swarm-services/web-services.yml web
    
    # Deploy monitoring services
    info "Deploying monitoring services..."
    docker stack deploy -c /opt/swarm-services/monitoring.yml monitoring
    
    # Deploy HAProxy and Keepalived (only on nodes with labels)
    if [[ "$CURRENT_SERVICES" == *"haproxy"* ]]; then
        info "Deploying load balancer services..."
        docker stack deploy -c /opt/swarm-services/haproxy-keepalived.yml loadbalancer
    fi
    
    log "All services deployed successfully"
    
    # Wait for services to start
    sleep 10
    
    # Show service status
    show_swarm_status
}

# Show swarm and service status
show_swarm_status() {
    log "Docker Swarm Status"
    
    echo
    info "=== Swarm Nodes ==="
    docker node ls
    
    echo
    info "=== Deployed Stacks ==="
    docker stack ls
    
    echo
    info "=== Services ==="
    docker service ls
    
    echo
    info "=== Service Details ==="
    docker stack ps web --no-trunc
    docker stack ps monitoring --no-trunc
    
    if docker stack ls | grep -q loadbalancer; then
        docker stack ps loadbalancer --no-trunc
    fi
    
    echo
    info "=== Access Points ==="
    info "Web Application: http://192.168.188.200 (via VIP)"
    info "Node.js API: http://192.168.188.200/node"
    info "HAProxy Stats: http://192.168.188.200:8404/stats"
    info "Portainer: http://192.168.188.52:9000"
    info "Swarm Visualizer: http://192.168.188.52:9001"
    
    echo
    info "=== Individual Node Access ==="
    for node in "${!NODE_IPS[@]}"; do
        local ip="${NODE_IPS[$node]}"
        info "$node: http://$ip:8080"
    done
}

# Leave swarm (for maintenance)
leave_swarm() {
    warning "Leaving Docker Swarm..."
    
    read -p "Are you sure you want to leave the swarm? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker swarm leave --force
        log "Left Docker Swarm"
    else
        info "Operation cancelled"
    fi
}

# Usage information
show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo
    echo "Commands:"
    echo "  init-manager     - Initialize Docker Swarm (run on rpi1)"
    echo "  join-manager     - Join as manager (run on rpi2)"
    echo "  join-worker      - Join as worker (run on rpi3, rpi4)"
    echo "  deploy-services  - Deploy all services to swarm"
    echo "  status          - Show swarm and service status"
    echo "  leave           - Leave the swarm"
    echo "  install-docker  - Install Docker if not present"
    echo
    echo "Setup Order:"
    echo "1. Run 'install-docker' on all nodes"
    echo "2. Run 'init-manager' on rpi1"
    echo "3. Run 'join-manager' on rpi2"
    echo "4. Run 'join-worker' on rpi3 and rpi4"
    echo "5. Run 'deploy-services' on any manager node"
}

# Main execution
main() {
    log "Docker Swarm Setup for Raspberry Pi Cluster"
    
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    check_root
    detect_node
    
    case "$1" in
        install-docker)
            install_docker
            ;;
        init-manager)
            if [[ "$CURRENT_NODE" != "rpi1" ]]; then
                error "init-manager should only be run on rpi1"
                exit 1
            fi
            install_docker
            init_swarm_manager
            ;;
        join-manager)
            if [[ "$CURRENT_NODE" != "rpi2" ]]; then
                error "join-manager should only be run on rpi2"
                exit 1
            fi
            install_docker
            join_swarm_manager
            ;;
        join-worker)
            if [[ "$CURRENT_ROLE" != "worker" ]]; then
                error "join-worker should only be run on worker nodes (rpi3, rpi4)"
                exit 1
            fi
            install_docker
            join_swarm_worker
            ;;
        deploy-services)
            deploy_services
            ;;
        status)
            show_swarm_status
            ;;
        leave)
            leave_swarm
            ;;
