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
# CLUSTER IDENTITY VARIABLES
# Centralise all cluster-specific names in one place so they're easy to update
# if your Dokploy stack prefix ever changes.
# ---------------------------------------------------------------------------
GALERA_HOST="${GALERA_NODE1_HOST:-erpdbcluster-cluster-0bxgsy_galera-node1}"
GALERA_PORT="${GALERA_NODE1_PORT:-3306}"
GALERA_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-Aa123123}"
PROXYSQL_HOST="${PROXYSQL_SERVICE_HOST:-erpdbcluster-cluster-0bxgsy_proxysql}"
PROXYSQL_PORT="6033"
PROXYSQL_ADMIN_PORT="6032"
PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

# The database name and user Frappe will own — must match your Galera env vars
DB_NAME="${FRAPPE_DB_NAME:-frappe_production}"
DB_USER="${FRAPPE_DB_USER:-frappe_user}"
# CRITICAL: This password is shared between Galera, ProxySQL mysql_users, and
# site_config.json. Passing --db-password to bench new-site pins this value
# and prevents the random-hash generation that breaks ProxySQL auth.
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
    # Point global bench default at ProxySQL for all runtime operations
    bench set-mariadb-host ${PROXYSQL_HOST}
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
    # FIX 1: GALERA READINESS WAIT
    # The Frappe container can start before Galera finishes WST/SST syncing.
    # We hard-block until node1 accepts connections or bail after 5 minutes.
    # ===========================================================================
    echo "⏳ Waiting for Galera node1 (${GALERA_HOST}:${GALERA_PORT}) to accept connections..."
    MAX_TRIES=60   # 60 × 5s = 5 minutes max
    TRIES=0
    until mysql -h "${GALERA_HOST}" -P "${GALERA_PORT}" \
          -u root -p"${GALERA_ROOT_PASS}" \
          --connect-timeout=3 \
          -e "SELECT 1;" > /dev/null 2>&1; do
        TRIES=$((TRIES + 1))
        if [ "$TRIES" -ge "$MAX_TRIES" ]; then
            echo "❌ FATAL: Galera node1 did not become available after $((MAX_TRIES * 5))s."
            exit 1
        fi
        echo "   Galera not ready (attempt ${TRIES}/${MAX_TRIES}), retrying in 5s..."
        sleep 5
    done
    echo "✅ Galera node1 is accepting connections."

    # ===========================================================================
    # FIX 2: PRE-PROVISION DATABASE AND USER WITH A KNOWN, STABLE PASSWORD
    #
    # bench new-site generates a random hash password for the db user UNLESS you
    # pass --db-password. We set the user up here first with a known password,
    # then pass that same password to bench so site_config.json stays consistent
    # with both Galera and ProxySQL's mysql_users table.
    #
    # We also grant root@'%' so bench can connect as root from any Swarm node IP.
    # The Bitnami image creates root@'localhost' only by default.
    # ===========================================================================
    echo "🔐 Pre-provisioning database schema and access credentials on Galera..."
    mysql -h "${GALERA_HOST}" -P "${GALERA_PORT}" \
          -u root -p"${GALERA_ROOT_PASS}" << SQLEOF
-- Create the application database
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

-- Create application user (idempotent)
CREATE USER IF NOT EXISTS '${DB_USER}'@'%'
    IDENTIFIED BY '${DB_PASS}';

-- Sync password in case user existed with a different one from a prior run
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';

-- Full privileges on the application schema
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';

-- bench new-site also creates internal _hash_named schemas for old-style setups;
-- the wildcard covers those even if --db-name is used
GRANT ALL PRIVILEGES ON \`_${DB_NAME}%\`.* TO '${DB_USER}'@'%';

-- Ensure root is accessible from any Swarm node IP (Bitnami defaults to localhost)
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%'
    IDENTIFIED BY '${GALERA_ROOT_PASS}'
    WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQLEOF

    if [ $? -ne 0 ]; then
        echo "❌ FATAL: Database pre-provisioning failed. Cannot continue."
        exit 1
    fi
    echo "✅ Database and credentials pre-provisioning complete."

    # Wait for Galera to replicate the DDL to node2 and node3 before ProxySQL
    # starts routing connections to them. Galera replication is near-synchronous
    # but give it a small buffer.
    echo "⏳ Holding 8s for Galera DDL replication across all nodes..."
    sleep 8

    # ===========================================================================
    # FIX 3: REGISTER frappe_user IN PROXYSQL'S ROUTING TABLE
    #
    # ProxySQL maintains its own mysql_users table and authenticates frontend
    # connections itself before proxying to a backend. If a user is not in this
    # table, ProxySQL returns "Access denied" regardless of what Galera has.
    # This is the exact source of the (1045) ProxySQL Error in your logs.
    # ===========================================================================
    echo "🔀 Registering application user in ProxySQL routing layer..."
    mysql -h "${PROXYSQL_HOST}" -P "${PROXYSQL_ADMIN_PORT}" \
          -u "${PROXYSQL_ADMIN_USER}" -p"${PROXYSQL_ADMIN_PASS}" << PROXYEOF
-- Remove stale entry from any prior failed run, then re-insert cleanly
DELETE FROM mysql_users WHERE username = '${DB_USER}';
INSERT INTO mysql_users (
    username,
    password,
    default_hostgroup,
    transaction_persistent,
    active
) VALUES (
    '${DB_USER}',
    '${DB_PASS}',
    1,     -- hostgroup 1 = your Galera write pool
    1,     -- keep transactions on the same backend node
    1
);
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
PROXYEOF

    PROXYSQL_STATUS=$?
    if [ $PROXYSQL_STATUS -ne 0 ]; then
        echo "⚠️ Warning: ProxySQL admin registration returned status ${PROXYSQL_STATUS}."
        echo "   Verify PROXYSQL_ADMIN_USER / PROXYSQL_ADMIN_PASS env vars match your ProxySQL config."
        echo "   Continuing — bench new-site targets Galera directly; ProxySQL is only needed at runtime."
    else
        echo "✅ frappe_user registered in ProxySQL."
    fi

    echo "🌐 Syncing database schema changes via direct Galera node1 connection..."

    # ===========================================================================
    # FIX 4: BENCH NEW-SITE WITH PINNED --db-password
    #
    # Three flags work together here:
    #   --db-name      → use the pre-provisioned schema, not a random _hash name
    #   --db-user      → use the pre-provisioned user, not a random _hash user
    #   --db-password  → PIN the password; without this bench generates a new random
    #                    password, stores it in site_config.json, and ProxySQL (which
    #                    still has the old password) rejects every subsequent connection
    #
    # --db-host points directly at galera-node1 (not ProxySQL) because:
    #   a) bench needs root access for CREATE DATABASE / GRANT which ProxySQL blocks
    #   b) we patch site_config.json to ProxySQL AFTER this step (FIX 5 below)
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

    # Clean trailing spaces/semicolons from the installation string to avoid broken chains
    CLEAN_INSTALL_CMDS=$(echo "$INSTALL_CMDS" | sed 's/[[:space:];]*$//')

    if [ -n "$CLEAN_INSTALL_CMDS" ]; then
        SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && ${CLEAN_INSTALL_CMDS}"
    fi

    # Finalize environment states
    SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && \
        bench --site ${FRAPPE_SITE_NAME} set-config developer_mode 1 && \
        bench --site ${FRAPPE_SITE_NAME} clear-cache && \
        bench use ${FRAPPE_SITE_NAME}"

    # Safe injection execution
    export SITE_SETUP_COMMANDS
    su frappe -s /bin/bash -c 'export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:$PATH" && eval "$SITE_SETUP_COMMANDS"'

    if [ $? -ne 0 ]; then
        echo "❌ FATAL: Framework app injection sync failed."
        exit 1
    fi

    echo "✅ Cluster schema sync complete!"

    # ===========================================================================
    # FIX 5: REDIRECT RUNTIME DB CONNECTIONS TO PROXYSQL
    #
    # bench new-site writes the --db-host value (galera-node1) into site_config.json.
    # If left as-is, every Frappe request bypasses ProxySQL and hits one raw Galera
    # node, breaking your HA topology. We patch the file back to ProxySQL here.
    # ===========================================================================
    SITE_CONFIG="/home/frappe/frappe-bench/sites/${FRAPPE_SITE_NAME}/site_config.json"
    echo "🔧 Redirecting runtime DB connections back to ProxySQL..."

    if [ -f "$SITE_CONFIG" ]; then
        python3 - << PYEOF
import json, sys

config_path = "${SITE_CONFIG}"

try:
    with open(config_path, "r") as f:
        config = json.load(f)

    config["db_host"] = "${PROXYSQL_HOST}"
    config["db_port"] = ${PROXYSQL_PORT}

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)

    print("✅ site_config.json patched: db_host → ${PROXYSQL_HOST}:${PROXYSQL_PORT}")
    sys.exit(0)
except Exception as e:
    print("⚠️ Patch failed: {}".format(e), file=sys.stderr)
    sys.exit(1)
PYEOF
        if [ $? -ne 0 ]; then
            echo "⚠️ Warning: site_config.json patch failed. Runtime will use galera-node1 directly."
            echo "   You can fix manually: set db_host=${PROXYSQL_HOST} db_port=${PROXYSQL_PORT} in ${SITE_CONFIG}"
        fi
    else
        echo "⚠️ Warning: site_config.json not found at expected path: ${SITE_CONFIG}"
    fi

    # Fix ownership after Python write
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
