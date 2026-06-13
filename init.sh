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

if [ -n "$IS_BUILDING_IMAGE" ] || [ "$1" = "--build-only" ]; then
    echo "⏩ Dokploy Image Build Phase detected. Bypassing database hooks cleanly..."
    echo "✅ Build step complete. Runtime scripts will execute upon container startup."
    exit 0
fi

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
# CLUSTER IDENTITY VARIABLES & ROUTING PROFILES
# ---------------------------------------------------------------------------
SWARM_OVERLAY_HOST="erpdbcluster-cluster-0bxgsy_galera-node1"

GALERA_HOST="${SWARM_OVERLAY_HOST}"
GALERA_PORT="${GALERA_NODE1_PORT:-3306}"
GALERA_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-Aa123123}"

PROXYSQL_RUNTIME_HOST="${PROXYSQL_SERVICE_HOST:-erpdbcluster-cluster-0bxgsy_proxysql}"
PROXYSQL_RUNTIME_PORT="6033"

PROXYSQL_ADMIN_HOST="erpdbcluster-cluster-0bxgsy_proxysql"
PROXYSQL_ADMIN_PORT=6032
PROXYSQL_ADMIN_USER="${PROXYSQL_ADMIN_USER:-admin}"
PROXYSQL_ADMIN_PASS="${PROXYSQL_ADMIN_PASS:-admin}"

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

    # ===========================================================================
    # ADJUSTMENT: TIMING CORRECTION
    # Postponed global bench redis networking configs, common_site_config 
    # db_host adjustments moved downstream to avoid hijacking site generation.
    # ===========================================================================

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
    # FIX A.1: GALERA READINESS LOOP VIA PYMYSQL INSTEAD OF MYSQL CLI
    # ===========================================================================
    echo "⏳ Waiting for Galera database engine via PyMySQL (${GALERA_HOST}:${GALERA_PORT})..."
    MAX_TRIES=60
    TRIES=0
    while true; do
        python3 -c "
import pymysql, sys
try:
    conn = pymysql.connect(host='${GALERA_HOST}', port=${GALERA_PORT}, user='root', password='${GALERA_ROOT_PASS}', connect_timeout=3)
    conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
"
        if [ $? -eq 0 ]; then
            echo "✅ Connected to Galera Active Cluster Mesh!"
            break
        fi

        TRIES=$((TRIES + 1))
        if [ "$TRIES" -ge "$MAX_TRIES" ]; then
            echo "❌ FATAL: Galera node did not become available at runtime initialization via PyMySQL."
            exit 1
        fi
        echo "   Galera not ready (attempt ${TRIES}/${MAX_TRIES}), retrying in 5s..."
        sleep 5
    done

    # ===========================================================================
    # FIX A.2: IDEMPOTENT DB & ROOT PROVISIONING VIA PYMYSQL INSTEAD OF MYSQL CLI
    # ===========================================================================
    echo "🔐 Pre-provisioning database schema and access credentials via PyMySQL..."
    python3 - << PYEOF
import pymysql, sys
try:
    conn = pymysql.connect(host='${GALERA_HOST}', port=${GALERA_PORT}, user='root', password='${GALERA_ROOT_PASS}')
    with conn.cursor() as cur:
        cur.execute("CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
        cur.execute("CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${GALERA_ROOT_PASS}';")
        cur.execute("GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;")
        cur.execute("ALTER USER 'root'@'%' IDENTIFIED BY '${GALERA_ROOT_PASS}';")
        cur.execute("CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';")
        cur.execute("ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';")
        cur.execute("GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';")
        cur.execute("GRANT ALL PRIVILEGES ON \`_${DB_NAME}%\`.* TO '${DB_USER}'@'%';")
        cur.execute("FLUSH PRIVILEGES;")
    conn.commit()
    conn.close()
    print("✅ Database and credentials pre-provisioning complete.")
except Exception as e:
    print(f"❌ FATAL: Database provisioning failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

    if [ $? -ne 0 ]; then exit 1; fi

    echo "⏳ Holding 5s for cluster synchronization..."
    sleep 5

    # ===========================================================================
    # FIX A.3: PROXYSQL REGISTRATION ROUTED VIA PYMYSQL INSTEAD OF MYSQL CLI
    # ===========================================================================
    echo "🔀 Registering credentials inside ProxySQL memory tables via PyMySQL..."
    python3 - << PYEOF
import pymysql, sys
try:
    conn = pymysql.connect(host='${PROXYSQL_ADMIN_HOST}', port=${PROXYSQL_ADMIN_PORT}, user='${PROXYSQL_ADMIN_USER}', password='${PROXYSQL_ADMIN_PASS}')
    with conn.cursor() as cur:
        cur.execute("DELETE FROM mysql_users WHERE username = %s;", ('${DB_USER}',))
        cur.execute("INSERT INTO mysql_users (username, password, default_hostgroup, transaction_persistent, active) VALUES (%s, %s, 1, 1, 1);", ('${DB_USER}', '${DB_PASS}'))
        cur.execute("DELETE FROM mysql_users WHERE username = 'root';")
        cur.execute("INSERT INTO mysql_users (username, password, default_hostgroup, transaction_persistent, active) VALUES (%s, %s, 1, 1, 1);", ('root', '${GALERA_ROOT_PASS}'))
        cur.execute("LOAD MYSQL USERS TO RUNTIME;")
        cur.execute("SAVE MYSQL USERS TO DISK;")
    conn.commit()
    conn.close()
    print("✅ Cluster users synchronized in ProxySQL database layer tables.")
except Exception as e:
    print(f"⚠️ Warning: ProxySQL admin credential update failed via PyMySQL: {e}", file=sys.stderr)
PYEOF

    echo "🌐 Syncing site structures through relational engines..."

    # ===========================================================================
    # FIX B: BENCH NEW-SITE PINNED SCHEMA SYSTEM (Bypassing common_site_config Interception)
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
    # ADJUSTMENT: RUN CONFIGS ONLY AFTER SUCCESSFUL NEW-SITE INITIALIZATION
    # Point global bench default at ProxySQL for subsequent execution layers
    # ===========================================================================
    echo "⚙️ Post-provisioning: Linking bench infrastructure to ProxySQL routing layers..."
    su frappe -s /bin/bash << EOF
export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:\$PATH"
cd /home/frappe/frappe-bench
bench set-mariadb-host ${PROXYSQL_RUNTIME_HOST}
bench set-config -g redis_cache redis://redis-cache:6379
bench set-config -g redis_queue redis://redis-queue:6379
bench set-config -g redis_socketio redis://redis-cache:6379
EOF

    # Re-verify and patch local specific site_config mappings back onto ProxySQL
    SITE_CONFIG="/home/frappe/frappe-bench/sites/${FRAPPE_SITE_NAME}/site_config.json"
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
    print("✅ site_config.json patched to ProxySQL overlay network context.")
except Exception as e:
    print(f"⚠️ Patch error: {e}")
PYEOF
    fi
    chown frappe:frappe "$SITE_CONFIG" 2>/dev/null || true
else
    echo "ℹ️ Existing initialization footprint located. Re-linking persistence directories..."
    rm -rf /home/frappe/frappe-bench/sites
    ln -s /storage/sites /home/frappe/frappe-bench/sites
    chmod -R 777 /storage/sites /storage/logs
    chown -R frappe:frappe /storage/sites /storage/logs
    chown -R frappe:frappe /home/frappe
    chown -h frappe:frappe /home/frappe/frappe-bench/sites
fi

# Sync metrics manifest
echo "frappe" > /storage/sites/apps.txt
if [ -f "/home/frappe/apps.txt" ]; then
    cat /home/frappe/apps.txt >> /storage/sites/apps.txt
fi
chmod 777 /storage/sites/apps.txt
chown frappe:frappe /storage/sites/apps.txt 2>/dev/null || true

# Generate production monitoring process layout profiles
SUPERVISOR_CONFIG_FILE="/home/frappe/frappe-bench/config/supervisor.conf"
rm -f "$SUPERVISOR_CONFIG_FILE"
su frappe -s /bin/bash << EOF
export PATH="/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:\$PATH"
cd /home/frappe/frappe-bench
bench setup supervisor --skip-redis
EOF

# Swap orchestration flags for uniform process layout handling
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

rm -f /home/frappe/.local/bin/supervisorctl
mkdir -p /etc/supervisor/conf.d/
ln -sf "$SUPERVISOR_CONFIG_FILE" /etc/supervisor/conf.d/frappe-bench.conf

echo "✅ Transferring master process orchestration over to Supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
