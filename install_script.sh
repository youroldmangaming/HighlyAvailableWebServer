#!/bin/bash

# High Availability Load Balancer Setup Script with Node.js
# Usage: ./setup_ha_lb.sh [master|backup|nginx]
# 
# Expected directory structure:
# ./configs/
# ├── haproxy.cfg
# ├── keepalived-master.conf
# ├── keepalived-backup.conf
# └── nginx-default

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration directory
CONFIG_DIR="$(dirname "$0")/configs"

# Node.js application directory
NODE_APP_DIR="/mnt/bigbird/nginx/data/node"
NGINX_DATA_DIR="/mnt/bigbird/nginx/data"

# Logging function
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

# Validate arguments
validate_args() {
    if [[ $# -ne 1 ]]; then
        error "Usage: $0 [master|backup|nginx]"
        exit 1
    fi

    case "$1" in
        master|backup|nginx)
            NODE_TYPE="$1"
            ;;
        *)
            error "Invalid argument. Use 'master', 'backup', or 'nginx'"
            exit 1
            ;;
    esac
}

# Check if configuration files exist
check_config_files() {
    log "Checking configuration files..."
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        error "Configuration directory '$CONFIG_DIR' not found"
        error "Please create the configs directory and place your configuration files there"
        exit 1
    fi

    local required_files=(
        "$CONFIG_DIR/haproxy.cfg"
        "$CONFIG_DIR/keepalived-master.conf"
        "$CONFIG_DIR/keepalived-backup.conf"
        "$CONFIG_DIR/nginx-default"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error "Required configuration file not found: $file"
            exit 1
        fi
    done

    info "All required configuration files found"
}

# Create configuration files from your provided configs
create_config_files() {
    log "Creating configuration directory and files..."
    
    mkdir -p "$CONFIG_DIR"

    # Create HAProxy config
    cat > "$CONFIG_DIR/haproxy.cfg" << 'EOF'
global
        log /dev/log    local0
        log /dev/log    local1 notice
        chroot /var/lib/haproxy
        stats socket /run/haproxy/admin.sock mode 660 level admin
        stats timeout 30s
        user haproxy
        group haproxy
        daemon

        # Default SSL material locations
        ca-base /etc/ssl/certs
        crt-base /etc/ssl/private

        # See: https://ssl-config.mozilla.org/#server=haproxy&server-version=2.0.3&config=intermediate
        ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
        ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
        log     global
        mode    http
        option  httplog
        option  dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000
        errorfile 400 /etc/haproxy/errors/400.http
        errorfile 403 /etc/haproxy/errors/403.http
        errorfile 408 /etc/haproxy/errors/408.http
        errorfile 500 /etc/haproxy/errors/500.http
        errorfile 502 /etc/haproxy/errors/502.http
        errorfile 503 /etc/haproxy/errors/503.http
        errorfile 504 /etc/haproxy/errors/504.http

frontend web_frontend
    bind *:80
    default_backend web_backend

backend web_backend
    balance roundrobin
    option httpchk GET /
    # Direct host IPs - no Docker networking issues
    server web_rpi1 192.168.188.52:8080 check inter 2s rise 2 fall 3
    server web_rpi2 192.168.188.39:8080 check inter 2s rise 2 fall 3
    server web_rpi3 192.168.188.33:8080 check inter 2s rise 2 fall 3
    server web_rpi4 192.168.188.41:8080 check inter 2s rise 2 fall 3

# Stats page
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
EOF

    # Create Keepalived master config
    cat > "$CONFIG_DIR/keepalived-master.conf" << 'EOF'
! Configuration File for keepalived

global_defs {
   notification_email {
     admin@yourdomain.com
   }
   notification_email_from keepalived@yourdomain.com
   smtp_server localhost
   smtp_connect_timeout 30
   router_id LVS_DEVEL_MASTER
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 110
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass your_password_here
    }
    virtual_ipaddress {
        192.168.188.200/24
    }

    # Optional: Health check script
    track_script {
        chk_haproxy
    }
}

# Optional: Health check for HAProxy
vrrp_script chk_haproxy {
    script "/bin/curl -f http://localhost:8404/stats || exit 1"
    interval 2
    weight -2
    fall 3
    rise 2
}
EOF

    # Create Keepalived backup config
    cat > "$CONFIG_DIR/keepalived-backup.conf" << 'EOF'
! Configuration File for keepalived

global_defs {
   notification_email {
     admin@yourdomain.com
   }
   notification_email_from keepalived@yourdomain.com
   smtp_server localhost
   smtp_connect_timeout 30
   router_id LVS_DEVEL_BACKUP
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass your_password_here
    }
    virtual_ipaddress {
        192.168.188.200/24
    }

    # Optional: Health check script
    track_script {
        chk_haproxy
    }
}

# Optional: Health check for HAProxy
vrrp_script chk_haproxy {
    script "/bin/curl -f http://localhost:8404/stats || exit 1"
    interval 2
    weight -2
    fall 3
    rise 2
}
EOF

    # Create Nginx default config with Node.js proxy
    cat > "$CONFIG_DIR/nginx-default" << 'EOF'
# Default server configuration with Node.js proxy
server {
        listen 8080 default_server;
        listen [::]:8080 default_server;

        # SSL configuration
        #
        # listen 443 ssl default_server;
        # listen [::]:443 ssl default_server;
        #
        # Note: You should disable gzip for SSL traffic.
        # See: https://bugs.debian.org/773332
        #
        # Read up on ssl_ciphers to ensure a secure configuration.
        # See: https://bugs.debian.org/765782
        #
        # Self signed certs generated by the ssl-cert package
        # Don't use them in a production server!
        #
        # include snippets/snakeoil.conf;

        root /mnt/bigbird/nginx/data;

        # Add index.php to the list if you are using PHP
        index index.html index.htm index.nginx-debian.html;

        server_name _;

        location / {
                # First attempt to serve request as file, then
                # as directory, then fall back to displaying a 404.
                try_files $uri $uri/ =404;
        }

        # Node.js application proxy
        location /node {
                proxy_pass http://localhost:3000;  # Your Node.js app port
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection 'upgrade';
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_cache_bypass $http_upgrade;
        }

        # deny access to .htaccess files, if Apache's document root
        # concurs with nginx's one
        location ~ /\.ht {
               deny all;
        }
}
EOF

    log "Configuration files created in $CONFIG_DIR"
}

# Update system packages
update_system() {
    log "Updating system packages..."
    apt update && apt upgrade -y
}

# Install required packages
install_packages() {
    log "Installing packages for $NODE_TYPE node..."
    
    if [[ "$NODE_TYPE" == "nginx" ]]; then
        apt install -y nginx nodejs npm curl net-tools
        log "Nginx, Node.js, npm and dependencies installed"
    else
        apt install -y nginx keepalived haproxy nodejs npm curl net-tools
        log "Nginx, keepalived, haproxy, Node.js, npm and dependencies installed"
    fi
}

# Setup Node.js application
setup_nodejs_app() {
    log "Setting up Node.js application..."
    
    # Create the directory structure
    mkdir -p "$NODE_APP_DIR"
    mkdir -p "$NGINX_DATA_DIR"
    
    # Change to the Node.js app directory
    cd "$NODE_APP_DIR"
    
    # Initialize npm project
    log "Initializing npm project..."
    npm init -y
    
    # Create the Node.js application
    log "Creating Node.js application..."
    cat > "$NODE_APP_DIR/app.js" << 'EOF'
const http = require('http');

const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<h1>Hello from Node.js!</h1>');
});

const PORT = 3000;
server.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
});
EOF

    # Create a systemd service for the Node.js app
    log "Creating systemd service for Node.js app..."
    cat > "/etc/systemd/system/nodejs-app.service" << EOF
[Unit]
Description=Node.js Application
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=$NODE_APP_DIR
ExecStart=/usr/bin/node app.js
Restart=on-failure
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=nodejs-app

[Install]
WantedBy=multi-user.target
EOF

    # Set proper ownership
    chown -R www-data:www-data "$NGINX_DATA_DIR"
    chmod +x "$NODE_APP_DIR/app.js"
    
    log "Node.js application setup completed"
}

# Configure HAProxy
configure_haproxy() {
    log "Configuring HAProxy..."
    
    # Backup original config if it exists
    if [[ -f /etc/haproxy/haproxy.cfg ]]; then
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.original
    fi

    # Copy our configuration
    cp "$CONFIG_DIR/haproxy.cfg" /etc/haproxy/haproxy.cfg
    
    # Set proper permissions
    chown root:root /etc/haproxy/haproxy.cfg
    chmod 644 /etc/haproxy/haproxy.cfg

    log "HAProxy configuration installed"
}

# Configure Keepalived based on node type
configure_keepalived() {
    log "Configuring Keepalived for $NODE_TYPE node..."
    
    # Backup original config if it exists
    if [[ -f /etc/keepalived/keepalived.conf ]]; then
        cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.original
    fi

    # Copy the appropriate configuration
    if [[ "$NODE_TYPE" == "master" ]]; then
        cp "$CONFIG_DIR/keepalived-master.conf" /etc/keepalived/keepalived.conf
    else
        cp "$CONFIG_DIR/keepalived-backup.conf" /etc/keepalived/keepalived.conf
    fi
    
    # Set proper permissions
    chown root:root /etc/keepalived/keepalived.conf
    chmod 644 /etc/keepalived/keepalived.conf

    log "Keepalived configuration for $NODE_TYPE installed"
}

# Configure Nginx
configure_nginx() {
    log "Configuring Nginx..."
    
    # Backup original config
    if [[ -f /etc/nginx/sites-available/default ]]; then
        cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.original
    fi

    # Copy our configuration
    cp "$CONFIG_DIR/nginx-default" /etc/nginx/sites-available/default
    
    # Set proper permissions
    chown root:root /etc/nginx/sites-available/default
    chmod 644 /etc/nginx/sites-available/default

    # Test nginx configuration
    nginx -t
    log "Nginx configuration installed and tested"
}

# Create a simple test page
create_test_page() {
    log "Creating test page..."
    
    HOSTNAME=$(hostname)
    NODE_IP=$(hostname -I | awk '{print $1}')
    
    cat > "$NGINX_DATA_DIR/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>HA Load Balancer - $NODE_TYPE Node</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .header { background-color: #f0f0f0; padding: 20px; border-radius: 5px; }
        .info { margin: 20px 0; }
        .status { color: green; font-weight: bold; }
        .service-links { margin: 20px 0; }
        .service-links a { 
            display: inline-block; 
            margin: 5px 10px; 
            padding: 10px 15px; 
            background-color: #007bff; 
            color: white; 
            text-decoration: none; 
            border-radius: 5px; 
        }
        .service-links a:hover { background-color: #0056b3; }
    </style>
</head>
<body>
    <div class="header">
        <h1>High Availability Load Balancer with Node.js</h1>
        <p class="status">Node Status: $NODE_TYPE</p>
    </div>
    <div class="info">
        <p><strong>Hostname:</strong> $HOSTNAME</p>
        <p><strong>IP Address:</strong> $NODE_IP</p>
        <p><strong>Node Type:</strong> $NODE_TYPE</p>
        <p><strong>Timestamp:</strong> $(date)</p>
    </div>
    <div class="info">
        <p><strong>Services:</strong></p>
        <ul>
            <li>Nginx: Running on port 8080</li>
            <li>Node.js: Running on port 3000 (proxied via /node)</li>
            <li>HAProxy: Running on port 80 (frontend), 8404 (stats)</li>
            <li>Keepalived: Managing VIP 192.168.188.200</li>
        </ul>
    </div>
    <div class="service-links">
        <p><strong>Test Links:</strong></p>
        <a href="/node" target="_blank">Node.js App</a>
        <a href="http://$NODE_IP:8404/stats" target="_blank">HAProxy Stats</a>
    </div>
</body>
</html>
EOF

    log "Test page created"
}

# Enable and start services
start_services() {
    log "Enabling and starting services..."
    
    # Reload systemd to recognize the new Node.js service
    systemctl daemon-reload
    
    if [[ "$NODE_TYPE" == "nginx" ]]; then
        # Nginx and Node.js for nginx-only nodes
        systemctl enable nginx
        systemctl enable nodejs-app
        systemctl restart nginx
        systemctl restart nodejs-app
        log "Nginx and Node.js services started"
    else
        # All services for master/backup nodes
        systemctl enable nginx
        systemctl enable haproxy
        systemctl enable keepalived
        systemctl enable nodejs-app
        
        systemctl restart nginx
        systemctl restart haproxy
        systemctl restart keepalived
        systemctl restart nodejs-app
        log "All services started"
    fi
    
    # Wait a moment for services to start
    sleep 5
}

# Check service status
check_services() {
    log "Checking service status..."
    
    if [[ "$NODE_TYPE" == "nginx" ]]; then
        # Check nginx and Node.js for nginx-only nodes
        services=("nginx" "nodejs-app")
    else
        # Check all services for master/backup nodes
        services=("nginx" "haproxy" "keepalived" "nodejs-app")
    fi

    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            info "$service is running"
        else
            error "$service is not running"
            systemctl status "$service" --no-pager
        fi
    done
}

# Check port bindings
check_ports() {
    log "Checking port bindings..."
    
    info "Port 8080 (Nginx):"
    ss -tlnp | grep :8080 || warning "Port 8080 not bound"
    
    info "Port 3000 (Node.js):"
    ss -tlnp | grep :3000 || warning "Port 3000 not bound"
    
    if [[ "$NODE_TYPE" != "nginx" ]]; then
        info "Port 80 (HAProxy frontend):"
        ss -tlnp | grep :80 || warning "Port 80 not bound"
        
        info "Port 8404 (HAProxy stats):"
        ss -tlnp | grep :8404 || warning "Port 8404 not bound"
    fi
}

# Display final information
display_info() {
    log "Installation completed successfully!"
    
    echo
    info "=== Configuration Summary ==="
    info "Node Type: $NODE_TYPE"
    
    if [[ "$NODE_TYPE" == "nginx" ]]; then
        info "Services:"
        info "  - Nginx: http://$(hostname -I | awk '{print $1}'):8080"
        info "  - Node.js: http://$(hostname -I | awk '{print $1}'):8080/node"
        
        echo
        info "=== Configuration Files ==="
        info "Nginx: /etc/nginx/sites-available/default"
        info "Node.js App: $NODE_APP_DIR/app.js"
        info "Node.js Service: /etc/systemd/system/nodejs-app.service"
        info "Original files backed up with .original extension"
        
        echo
        info "=== Useful Commands ==="
        info "Check service status:"
        info "  systemctl status nginx nodejs-app"
        echo
        info "View logs:"
        info "  journalctl -u nginx -f"
        info "  journalctl -u nodejs-app -f"
        echo
        info "Test connectivity:"
        info "  curl http://localhost:8080"
        info "  curl http://localhost:8080/node"
        
    else
        info "Virtual IP: 192.168.188.200"
        info "Services:"
        info "  - Nginx: http://$(hostname -I | awk '{print $1}'):8080"
        info "  - Node.js: http://$(hostname -I | awk '{print $1}'):8080/node"
        info "  - HAProxy Stats: http://$(hostname -I | awk '{print $1}'):8404/stats"
        info "  - Load Balancer: http://192.168.188.200 (via VIP)"
        
        echo
        info "=== Configuration Files ==="
        info "HAProxy: /etc/haproxy/haproxy.cfg"
        info "Keepalived: /etc/keepalived/keepalived.conf"
        info "Nginx: /etc/nginx/sites-available/default"
        info "Node.js App: $NODE_APP_DIR/app.js"
        info "Node.js Service: /etc/systemd/system/nodejs-app.service"
        info "Original files backed up with .original extension"
        
        echo
        info "=== Useful Commands ==="
        info "Check service status:"
        info "  systemctl status nginx haproxy keepalived nodejs-app"
        echo
        info "View logs:"
        info "  journalctl -u nginx -f"
        info "  journalctl -u haproxy -f"
        info "  journalctl -u keepalived -f"
        info "  journalctl -u nodejs-app -f"
        echo
        info "Test connectivity:"
        info "  curl http://localhost:8080"
        info "  curl http://localhost:8080/node"
        info "  curl http://localhost:8404/stats"
        
        if [[ "$NODE_TYPE" == "master" ]]; then
            echo
            warning "Remember to:"
            warning "1. Set up the backup node with: $0 backup"
            warning "2. Update the authentication password in keepalived.conf"
            warning "3. Adjust network interface if not 'eth0'"
            warning "4. Configure your backend servers (RPi nodes)"
        fi
    fi
    
    echo
    info "=== Node.js Development ==="
    info "App directory: $NODE_APP_DIR"
    info "To modify the Node.js app:"
    info "  1. Edit $NODE_APP_DIR/app.js"
    info "  2. Restart service: systemctl restart nodejs-app"
    info "  3. Check logs: journalctl -u nodejs-app -f"
}

# Main execution
main() {
    log "Starting High Availability Load Balancer setup with Node.js..."
    
    check_root
    validate_args "$@"
    
    info "Setting up $NODE_TYPE node..."
    
    # Check if config files exist, if not create them
    if [[ ! -d "$CONFIG_DIR" ]]; then
        warning "Configuration directory not found, creating default configs..."
        create_config_files
    else
        check_config_files
    fi
    
    update_system
    install_packages
    setup_nodejs_app
    
    if [[ "$NODE_TYPE" == "nginx" ]]; then
        # Nginx-only setup
        configure_nginx
        create_test_page
        start_services
        check_services
        check_ports
    else
        # Full HA setup (master/backup)
        configure_haproxy
        configure_keepalived
        configure_nginx
        create_test_page
        start_services
        check_services
        check_ports
    fi
    
    display_info
    
    log "Setup completed successfully!"
}

# Run main function with all arguments
main "$@"
