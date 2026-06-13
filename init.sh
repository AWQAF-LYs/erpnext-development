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
BUILD_ROUTING_GATEWAY="172.17.0.1"

# Build phase connections use host mesh routing to escape Dokploy isolation
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
    ln -s /storage/sites /home/frappe/frappe-bench/sites

    # Remap ownership immediately after the template files are copied
    chmod -R 777 /storage/sites /storage/logs
    chown -R frappe:frappe /storage/sites /storage/logs
    chown -R frappe:frappe /home/frappe
    chown -h frappe:frappe /home/frappe/frappe-bench/sites

    echo "⚙️ Networking application layers into cluster configurations..."
    su frappe -s /bin/bash << EOF
export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:\$PATH"
cd /home/frappe/frappe-bench
bench set-mariadb-host ${PROXYSQL_RUNTIME_HOST}
bench set-config -g redis_cache redis://redis-cache:6379
bench set-config -g redis_queue redis://redis-queue:6379
bench set-config -g redis_socketio redis://redis-cache:6379
EOF

    # Parse custom applications array list
    APPS_FILE_PATH="/home/frappe/apps.txt"
    FETCH_CMDS=""
    INSTALL_CMDS=""

    if [ -f "$APPS_FILE_PATH" ]; then
        while IFS= read -r app_name || [ -n "$app_name" ]; do
            app_name_trimmed=$(echo "$app_name" | tr -d '\r' | xargs)
            if [ -n "$app_name_trimmed" ]; then
                echo "   -> Queuing custom module app setup: $app_name_trimmed"
                FETCH_CMDS="${FETCH_CMDS}bench get-app ${app_name_trimmed} --branch ${FRAPPE_BRANCH}; "
                INSTALL_CMDS="${INSTALL_CMDS}bench --site ${FRAPPE_SITE_NAME} install-app ${app_name_trimmed}; "
            fi
        done < "$APPS_FILE_PATH"
    fi

    if [ -n "$FETCH_CMDS" ]; then
        echo "📦 Downloading linked app files..."
        su frappe -s /bin/bash << EOF
export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:\$PATH"
cd /home/frappe/frappe-bench
$FETCH_CMDS
EOF
    fi

    # ===========================================================================
    # FIX 1: GALERA READINESS WAIT (Routed via Host Bridge Gateway)
    # ===========================================================================
    echo "⏳ Waiting for Galera node1 via Host Bridge Mesh (${GALERA_HOST}:${GALERA_PORT})..."
    MAX_TRIES=60
    TRIES=0
    until mysql -h "${GALERA_HOST}" -P "${GALERA_PORT}" \
          -u root -p"${GALERA_ROOT_PASS}" \
          --connect-timeout=3 \
          -e "SELECT 1;" > /dev/null 2>&1; do
        TRIES=$((TRIES + 1))
        if [ "$TRIES" -ge "$MAX_TRIES" ]; then
            echo "❌ FATAL: Galera node1 did not become available via host mesh after $((MAX_TRIES * 5))s."
            exit 1
        fi
        echo "   Galera not ready (attempt ${TRIES}/${MAX_TRIES}), retrying in 5s..."
        sleep 5
    done
    echo "✅ Galera host connection interface verified."

    # ===========================================================================
    # FIX 2: PRE-PROVISION IDEMPOTENT DATABASE & GLOBAL USER CLEARANCES
    # ===========================================================================
    echo "🔐 Pre-provisioning database schema and access credentials on Galera..."
    mysql -h "${GALERA_HOST}" -P "${GALERA_PORT}" \
          -u root -p"${GALERA_ROOT_PASS}" <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${GALERA_ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
ALTER USER 'root'@'%' IDENTIFIED BY '${GALERA_ROOT_PASS}';

CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`_${DB_NAME}%\`.* TO '${DB_USER}'@'%';

FLUSH PRIVILEGES;
SQLEOF

    if [ $? -ne 0 ]; then
        echo "❌ FATAL: Database pre-provisioning failed. Cannot continue."
        exit 1
    fi
    echo "✅ Database and credentials pre-provisioning complete."

    echo "⏳ Holding 8s for Galera DDL replication across cluster..."
    sleep 8

    # ===========================================================================
    # FIX 3: REGISTER INTERNALS INTO PROXYSQL CORE VIA 6032 HOST MAPPING
    # ===========================================================================
    echo "🔀 Registering application user inside ProxySQL runtime memory tables..."
    mysql -h "${PROXYSQL_ADMIN_HOST}" -P "${PROXYSQL_ADMIN_PORT}" \
          -u "${PROXYSQL_ADMIN_USER}" -p"${PROXYSQL_ADMIN_PASS}" <<PROXYEOF
DELETE FROM mysql_users WHERE username = '${DB_USER}';
INSERT INTO mysql_users (username, password, default_hostgroup, transaction_persistent, active) 
VALUES ('${DB_USER}', '${DB_PASS}', 1, 1, 1);

DELETE FROM mysql_users WHERE username = 'root';
INSERT INTO mysql_users (username, password, default_hostgroup, transaction_persistent, active) 
VALUES ('root', '${GALERA_ROOT_PASS}', 1, 1, 1);

LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
PROXYEOF

    PROXYSQL_STATUS=$?
    if [ $PROXYSQL_STATUS -ne 0 ]; then
        echo "⚠️ Warning: ProxySQL admin credential update failed with exit status ${PROXYSQL_STATUS}."
        echo "   Continuing — database compilation handles migrations via direct node injection."
    else
        echo "✅ Cluster users synchronized in ProxySQL database layer tables."
    fi

    echo "🌐 Syncing database schema changes via direct Galera node link..."

    # ===========================================================================
    # FIX 4: BENCH NEW-SITE WITH EXPLICIT DUAL PINNED SCHEMAS
    # ===========================================================================
    SITE_SETUP_COMMANDS="cd /home/frappe/frappe-bench && \
        bench new-site ${FRAPPE_SITE_NAME} \
        --force \
        --db-name=${DB_NAME} \
        --db-user=${DB_USER} \
        --db-password=${DB_PASS} \
        --mariadb-user-host-login-scope='%' \
        --db-host=${GALERA_HOST} \
        --db-port=${GALERA_PORT} \
        --db-root-username=root \
        --db-root-password=${GALERA_ROOT_PASS} \
        --admin-password=${RUN_TIME_ADMIN_PASS}"

    CLEAN_INSTALL_CMDS=$(echo "$INSTALL_CMDS" | sed 's/[[:space:];]*$//')

    if [ -n "$CLEAN_INSTALL_CMDS" ]; then
        SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && ${CLEAN_INSTALL_CMDS}"
    fi

    SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && \
        bench --site ${FRAPPE_SITE_NAME} set-config developer_mode 1 && \
        bench --site ${FRAPPE_SITE_NAME} clear-cache && \
        bench use ${FRAPPE_SITE_NAME}"

    export SITE_SETUP_COMMANDS
    su frappe -s /bin/bash -c 'export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:$PATH" && eval "$SITE_SETUP_COMMANDS"'

    if [ $? -ne 0 ]; then
        echo "❌ FATAL: Framework app injection sync failed."
        exit 1
    fi

    echo "✅ Cluster schema sync complete!"

    # ===========================================================================
    # FIX 5: REDIRECT PRODUCTION CONTAINER ROUTING BACK TO PROXYSQL OVERLAY
    # ===========================================================================
    SITE_CONFIG="/home/frappe/frappe-bench/sites/${FRAPPE_SITE_NAME}/site_config.json"
    echo "🔧 Patching production target mappings back onto ProxySQL overlay mesh..."

    if [ -f "$SITE_CONFIG" ]; then
        python3 - << PYEOF
import json, sys

config_path = "${SITE_CONFIG}"

try:
    with open(config_path, "r") as f:
        config = json.load(f)

    config["db_host"] = "${PROXYSQL_RUNTIME_HOST}"
    config["db_port"] = ${PROXYSQL_RUNTIME_PORT}

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)

    print("✅ site_config.json patched: db_host → ${PROXYSQL_RUNTIME_HOST}:${PROXYSQL_RUNTIME_PORT}")
    sys.exit(0)
except Exception as e:
    print("⚠️ Patch failed: {}".format(e), file=sys.stderr)
    sys.exit(1)
PYEOF
        if [ $? -ne 0 ]; then
            echo "⚠️ Warning: Automated site_config.json patch failed."
        fi
    else
        echo "⚠️ Warning: site_config.json target footprint missing."
    fi

    chown frappe:frappe "$SITE_CONFIG" 2>/dev/null || true

else
    echo "ℹ️ Existing cluster initialization detected. Re-linking shared storage path..."
    rm -rf /home/frappe/frappe-bench/sites
    ln -s /storage/sites /home/frappe/frappe-bench/sites
    chmod -R 777 /storage/sites /storage/logs
    chown -R frappe:frappe /storage/sites /storage/logs
    chown -R frappe:frappe /home/frappe
    chown -h frappe:frappe /home/frappe/frappe-bench/sites
fi

# Sync application maps across cluster nodes
echo "frappe" > /storage/sites/apps.txt
if [ -f "/home/frappe/apps.txt" ]; then
    cat /home/frappe/apps.txt >> /storage/sites/apps.txt
fi
chmod 777 /storage/sites/apps.txt
chown frappe:frappe /storage/sites/apps.txt 2>/dev/null || true

# Generate process manager properties configurations
SUPERVISOR_CONFIG_FILE="/home/frappe/frappe-bench/config/supervisor.conf"
rm -f "$SUPERVISOR_CONFIG_FILE"
su frappe -s /bin/bash << EOF
export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:\$PATH"
cd /home/frappe/frappe-bench
bench setup supervisor --skip-redis
EOF

# Adjust worker parameters for the unified image layout
NEW_WEB_COMMAND="/home/frappe/.local/bin/bench serve --port ${FRAPPE_INTERNAL_PORT}"
NEW_WEB_DIRECTORY="/home/frappe/frappe-bench"
TEMP_AWK_OUTPUT_FILE="${SUPERVISOR_CONFIG_FILE}.tmp"

if [ -f "$SUPERVISOR_CONFIG_FILE" ]; then
    awk -v cmd="$NEW_WEB_COMMAND" -v dir="$NEW_WEB_DIRECTORY" '
    BEGIN { state = 0; }
    /\[program:frappe-bench-frappe-web\]/ { state = 1; print $0; next; }
    (state == 1 && $0 ~ /^[[:space:]]*\[program:/ && $0 !~ /\[program:frappe-bench-frappe-web\]/) { state = 0; }
    (state == 1) {
        if ($0 ~ /^command=/) { print "command=" cmd; next; }
        if ($0 ~ /^directory=/) { print "directory=" dir; next; }
        if ($0 ~ /gunicorn/ || $0 ~ /frappe\.app:application/) {
            print "# Overridden: " $0; next;
        }
    }
    { print $0; }
    ' "$SUPERVISOR_CONFIG_FILE" > "$TEMP_AWK_OUTPUT_FILE"

    mv "$TEMP_AWK_OUTPUT_FILE" "$SUPERVISOR_CONFIG_FILE"
    chown frappe:frappe "$SUPERVISOR_CONFIG_FILE"
fi

# Clean up our temporary mock script binary before passing execution over to the live orchestrator
rm -f /home/frappe/.local/bin/supervisorctl

mkdir -p /etc/supervisor/conf.d/
ln -sf "$SUPERVISOR_CONFIG_FILE" /etc/supervisor/conf.d/frappe-bench.conf

echo "✅ Transferring master process orchestration over to Supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
