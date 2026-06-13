#!/bin/bash

# Safe run helper to stop minor OS configuration tasks from killing the container
safe_run() {
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        echo "⚠️ Warning: Command '$*' returned status ($status). Proceeding securely..."
    fi
    return $status
}

echo "🏁 Container execution engine running..."

FRAPPE_SITE_NAME=${FRAPPE_SITE_NAME:-"erp.local"}
FRAPPE_INTERNAL_PORT=${FRAPPE_INTERNAL_PORT:-8000}
FRAPPE_BRANCH=${FRAPPE_BRANCH:-"version-15"}
RUN_TIME_ADMIN_PASS="${FRAPPE_ADMIN_PASSWORD:-admin123123}"

# Configure background secure access points safely
if [ -f "/etc/ssh/sshd_config" ]; then
    safe_run sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
fi
safe_run service ssh start 2>/dev/null || true

# Ingest configuration mappings if present
ENV_CONFIG_FILE="/home/frappe/env.config"
if [ -f "$ENV_CONFIG_FILE" ]; then
    echo "ℹ️ Loading initialization configuration parameters..."
    set -o allexport
    source "$ENV_CONFIG_FILE"
    set +o allexport
fi

# Safeguard check to alert you in logs if Dokploy variables are missing
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    echo "⚠️ WARNING: MYSQL_ROOT_PASSWORD environment variable is empty! Using fallback..."
fi

echo "🚀 Site Configuration Target: $FRAPPE_SITE_NAME on Port: $FRAPPE_INTERNAL_PORT"

# ---------------------------------------------------------------------------
# CLUSTER IDENTITY VARIABLES & DOCKER BRIDGE ROUTING OVERRIDES
# ---------------------------------------------------------------------------
# [FIX]: During Dokploy's build stage, the container is isolated. We route 
# through the host docker gateway (172.17.0.1) to hit published swarm node ports.
BUILD_ROUTING_GATEWAY="172.17.0.1"

# Build phase connections use host mesh routing
GALERA_HOST="${BUILD_ROUTING_GATEWAY}"
GALERA_PORT="${GALERA_NODE1_PORT:-3306}"
GALERA_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-Aa123123}"

# Runtime connections use the internal Swarm overlay names
PROXYSQL_RUNTIME_HOST="${PROXYSQL_SERVICE_HOST:-erpdbcluster-cluster-0bxgsy_proxysql}"
PROXYSQL_RUNTIME_PORT="6033"

# ProxySQL admin interface targeted via host gateway port mapping
PROXYSQL_ADMIN_HOST="${BUILD_ROUTING_GATEWAY}"
PROXYSQL_ADMIN_PORT="6032"
PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

# Database parameters
DB_NAME="${FRAPPE_DB_NAME:-frappe_production}"
DB_USER="${FRAPPE_DB_USER:-frappe_user}"
DB_PASS="${FRAPPE_DB_PASSWORD:-Aa123123}"

# Create a physical supervisorctl mock binary to safely intercept Python subprocess hooks
mkdir -p /home/frappe/.local/bin
cat << 'EOF' > /home/frappe/.local/bin/supervisorctl
#!/bin/sh
echo "Muted Supervisor Hook (${*})"
exit 0
EOF
chmod +x /home/frappe/.local/bin/supervisorctl
chown frappe:frappe /home/frappe/.local/bin/supervisorctl

# Ensure both sites AND logs persistent network volumes exist with wide open clearances
mkdir -p /storage/sites /storage/logs
chmod -R 777 /storage/sites /storage/logs
chown -R frappe:frappe /storage/sites /storage/logs

# --- Bench Framework Engine Initialization ---
if [ ! -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "🛠️ Creating structural bench base files inside high-performance layer..."

    su frappe -s /bin/bash << EOF
    export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:\$PATH"
    bench init --frappe-branch ${FRAPPE_BRANCH} --skip-redis-config-generation /home/frappe/frappe-bench
EOF
    if [ $? -ne 0 ]; then echo "❌ FATAL: Core framework initialization failed."; exit 1; fi

    echo "🔗 Linking bench sites array directly to High-Availability Storage Volume..."
    if [ -z "$(ls -A /storage/sites)" ]; then
        cp -R /home/frappe/frappe-bench/sites/* /storage/sites/ 2>/dev/null || true
    fi
    rm -rf /home/frappe/frappe-bench/sites
    ln -s /storage/sites /home/frappe/frappe-bench
