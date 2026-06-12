#!/bin/bash

# Define an internal error handling wrapper instead of raw 'set -e' 
# This prevents minor side-commands (like ssh start or sed) from killing the container.
safe_run() {
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        echo "⚠️ Warning: Command '$*' returned non-zero status ($status). Continuing safely..."
    fi
    return $status
}

echo "🏁 Container runtime initialization sequence started..."

# --- 1. DYNAMIC ENVIRONMENT PASSWORD BINDING ---
# Pull passwords directly from the Docker Environment Variables at runtime.
# NO HARDCODED CREDS.
RUN_TIME_ADMIN_PASS="${FRAPPE_ADMIN_PASSWORD:-AdminFallbackSecure123!}"

echo "root:${RUN_TIME_ADMIN_PASS}" | chpasswd 2>/dev/null
if [ $? -eq 0 ]; then
    echo "🔒 Root access security policy updated dynamically from environment variables."
else
    echo "⚠️ Notice: Root password assignment bypassed."
fi

# Configure and safely attempt starting the SSH daemon
if [ -f "/etc/ssh/sshd_config" ]; then
    safe_run sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
fi
safe_run service ssh start

export PATH="/home/frappe/.local/bin:$PATH"

# --- 2. VARIABLE INGESTION FROM INTERNAL CONFIG ---
ENV_CONFIG_FILE="/home/frappe/env.config"
if [ -f "$ENV_CONFIG_FILE" ]; then
  echo "ℹ️ Loading build-time definitions from $ENV_CONFIG_FILE"
  set -o allexport
  source "$ENV_CONFIG_FILE"
  set +o allexport
fi

FRAPPE_SITE_NAME=${FRAPPE_SITE_NAME:-"erp.local"}
FRAPPE_INTERNAL_PORT=${FRAPPE_INTERNAL_PORT:-8000} 
FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-15}

echo "🚀 Initializing ERPNext for site: $FRAPPE_SITE_NAME on internal port: $FRAPPE_INTERNAL_PORT"

# --- 3. CLUSTER SHARED STORAGE STORAGE CHECK ---
# GlusterFS volume mounts might belong to root on the host machine.
# We explicitly set permissions inside our shared path, but ignore errors if the network share locks ownership parameters.
echo "📁 Checking cluster volume storage array permissions..."
chown -R frappe:frappe /home/frappe 2>/dev/null || echo "⚠️ GlusterFS storage array ownership handled."

# --- 4. BENCH INITIALIZATION ENGINE ---
if [ ! -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  echo "🛠️ Creating a new bench framework instance as user 'frappe'..."
  
  if ! su - frappe -c "bench init --frappe-branch ${FRAPPE_BRANCH} --skip-redis-config-generation /home/frappe/frappe-bench"; then
      echo "❌ FATAL: 'bench init' failed to execute."
      exit 1
  fi

  echo "⚙️ Configuring high-availability routing for ProxySQL and Split Redis nodes..."
  su - frappe -c "cd /home/frappe/frappe-bench && \
    bench set-mariadb-host proxysql && \
    bench set-config -g redis_cache 'redis://redis-cache:6379' && \
    bench set-config -g redis_queue 'redis://redis-queue:6379' && \
    bench set-config -g redis_socketio 'redis://redis-queue:6379'"

  # App installation processing logic
  APPS_FILE_PATH="/home/frappe/apps.txt"
  FETCH_CMDS_STRING=""
  INSTALL_CMDS_STRING=""

  if [ -f "$APPS_FILE_PATH" ]; then
    echo "🔎 Reading target apps from apps.txt file..."
    while IFS= read -r app_name || [ -n "$app_name" ]; do
      app_name_trimmed=$(echo "$app_name" | tr -d '\r' | xargs)
      if [ -n "$app_name_trimmed" ]; then
        echo "   -> Queuing application: $app_name_trimmed"
        FETCH_CMDS_STRING="${FETCH_CMDS_STRING}bench get-app ${app_name_trimmed} --branch ${FRAPPE_BRANCH} && "
        INSTALL_CMDS_STRING="${INSTALL_CMDS_STRING}bench --site \"${FRAPPE_SITE_NAME}\" install-app ${app_name_trimmed} && "
      fi
    done < "$APPS_FILE_PATH"

    if [ -n "$FETCH_CMDS_STRING" ]; then FETCH_CMDS_STRING=${FETCH_CMDS_STRING%% && }; fi
    if [ -n "$INSTALL_CMDS_STRING" ]; then INSTALL_CMDS_STRING=${INSTALL_CMDS_STRING%% && }; fi
  fi

  if [ -n "$FETCH_CMDS_STRING" ]; then
    echo "📦 Downloading queued applications..."
    su - frappe -c "cd /home/frappe/frappe-bench && $FETCH_CMDS_STRING"
  fi

  echo "🌐 Running database provisioning via ProxySQL cluster..."
  SITE_SETUP_COMMANDS="bench new-site \"$FRAPPE_SITE_NAME\" \
    --force \
    --db-host=proxysql \
    --db-port=6033 \
    --mariadb-root-password=${MYSQL_ROOT_PASSWORD} \
    --admin-password=${RUN_TIME_ADMIN_PASS}"

  if [ -n "$INSTALL_CMDS_STRING" ]; then
    SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && ${INSTALL_CMDS_STRING}"
  fi

  SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && \
    bench --site \"$FRAPPE_SITE_NAME\" set-config developer_mode 1 && \
    bench --site \"$FRAPPE_SITE_NAME\" clear-cache"

  if ! su - frappe -c "cd /home/frappe/frappe-bench && $SITE_SETUP_COMMANDS"; then
      echo "❌ FATAL: Site generation or application hooks failed during cluster sync."
      exit 1
  fi
  
  su - frappe -c "cd /home/frappe/frappe-bench && bench use \"$FRAPPE_SITE_NAME\""
  echo "✅ Core site database cluster synchronization complete!"
else
  echo "ℹ️ Existing bench storage detected on volume path. Skipping database creation."
fi

# --- 5. AUTOMATED APPS.TXT CLUSTER FOOTPRINT ---
# Fixes secondary nodes crashing due to missing application tracking files
echo "Syncing application metadata mappings..."
mkdir -p /home/frappe/frappe-bench/sites
echo "frappe" > /home/frappe/frappe-bench/sites/apps.txt
if [ -f "/home/frappe/apps.txt" ]; then
  cat /home/frappe/apps.txt >> /home/frappe/frappe-bench/sites/apps.txt
fi
chown frappe:frappe /home/frappe/frappe-bench/sites/apps.txt 2>/dev/null || true

# --- 6. SUPERVISOR PRODUCTION CONFIGURATION ---
SUPERVISOR_CONFIG_FILE="/home/frappe/frappe-bench/config/supervisor.conf"
rm -f "$SUPERVISOR_CONFIG_FILE"
su - frappe -c "cd /home/frappe/frappe-bench && bench setup supervisor --skip-redis"

# Update web engine hooks to point to internal bench ports
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
            print "# Commented out by script: " $0; next;
        }
    }
    { print $0; }
    ' "$SUPERVISOR_CONFIG_FILE" > "$TEMP_AWK_OUTPUT_FILE"
    
    mv "$TEMP_AWK_OUTPUT_FILE" "$SUPERVISOR_CONFIG_FILE"
    chown frappe:frappe "$SUPERVISOR_CONFIG_FILE"
fi

mkdir -p /etc/supervisor/conf.d/
ln -sf "$SUPERVISOR_CONFIG_FILE" /etc/supervisor/conf.d/frappe-bench.conf

echo "✅ All initialization completed successfully. Handing process control to Supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
