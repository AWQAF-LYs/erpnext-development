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

FRAPPE_SITE_NAME=${FRAPPE_SITE_NAME:-"erp.local"}
FRAPPE_INTERNAL_PORT=${FRAPPE_INTERNAL_PORT:-8000} 
FRAPPE_BRANCH=${FRAPPE_BRANCH:-"version-15"}

echo "🚀 Site Configuration Target: $FRAPPE_SITE_NAME on Port: $FRAPPE_INTERNAL_PORT"

# Ensure the shared network mount points are ready and owned by the frappe worker context
mkdir -p /storage/sites
chown -R frappe:frappe /storage/sites

# --- Bench Framework Engine Initialization ---
if [ ! -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  echo "🛠️ Creating structural bench base files inside high-performance layer..."
  
  # Standard login subshell invocation works natively now that .pyenv is preserved
  if ! su - frappe -c "bench init --frappe-branch ${FRAPPE_BRANCH} --skip-redis-config-generation /home/frappe/frappe-bench"; then
      echo "❌ FATAL: Core framework initialization failed."
      exit 1
  fi

  echo "🔗 Linking bench sites array directly to High-Availability Storage Volume..."
  # If the shared volume is empty, migrate the initial structural framework boilerplate across
  if [ -z "$(ls -A /storage/sites)" ]; then
      cp -R /home/frappe/frappe-bench/sites/* /storage/sites/
  fi
  rm -rf /home/frappe/frappe-bench/sites
  ln -s /storage/sites /home/frappe/frappe-bench/sites
  chown -h frappe:frappe /home/frappe/frappe-bench/sites

  echo "⚙️ Networking application layers into cluster configurations..."
  su - frappe -c "cd /home/frappe/frappe-bench && \
    bench set-mariadb-host proxysql && \
    bench set-config -g redis_cache 'redis://redis-cache:6379' && \
    bench set-config -g redis_queue 'redis://redis-queue:6379' && \
    bench set-config -g redis_socketio 'redis://redis-cache:6379'"

  # Parse custom applications array list
  APPS_FILE_PATH="/home/frappe/apps.txt"
  FETCH_CMDS_STRING=""
  INSTALL_CMDS_STRING=""

  if [ -f "$APPS_FILE_PATH" ]; then
    while IFS= read -r app_name || [ -n "$app_name" ]; do
      app_name_trimmed=$(echo "$app_name" | tr -d '\r' | xargs)
      if [ -n "$app_name_trimmed" ]; then
        echo "   -> Queuing custom module app setup: $app_name_trimmed"
        FETCH_CMDS_STRING="${FETCH_CMDS_STRING}bench get-app ${app_name_trimmed} --branch ${FRAPPE_BRANCH} && "
        INSTALL_CMDS_STRING="${INSTALL_CMDS_STRING}bench --site \"${FRAPPE_SITE_NAME}\" install-app ${app_name_trimmed} && "
      fi
    done < "$APPS_FILE_PATH"

    if [ -n "$FETCH_CMDS_STRING" ]; then FETCH_CMDS_STRING=${FETCH_CMDS_STRING%% && }; fi
    if [ -n "$INSTALL_CMDS_STRING" ]; then INSTALL_CMDS_STRING=${INSTALL_CMDS_STRING%% && }; fi
  fi

  if [ -n "$FETCH_CMDS_STRING" ]; then
    echo "📦 Downloading linked app files..."
    su - frappe -c "cd /home/frappe/frappe-bench && $FETCH_CMDS_STRING"
  fi

  echo "🌐 Syncing database schema changes via ProxySQL multi-master cluster..."
  # FIXED: Swapped escaped double quotes to resolve evaluation parsing errors in Python click inputs
  SITE_SETUP_COMMANDS="bench new-site \"$FRAPPE_SITE_NAME\" \
    --force \
    --db-host=proxysql \
    --db-port=6033 \
    --mariadb-root-password=\"$MYSQL_ROOT_PASSWORD\" \
    --admin-password=\"$RUN_TIME_ADMIN_PASS\""

  if [ -n "$INSTALL_CMDS_STRING" ]; then
    SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && ${INSTALL_CMDS_STRING}"
  fi

  SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && \
    bench --site \"$FRAPPE_SITE_NAME\" set-config developer_mode 1 && \
    bench --site \"$FRAPPE_SITE_NAME\" clear-cache"

  if ! su - frappe -c "supervisorctl() { echo 'Muted Supervisor Hook'; }; export -f supervisorctl; cd /home/frappe/frappe-bench && $SITE_SETUP_COMMANDS"; then
      echo "❌ FATAL: Framework app injection sync failed."
      exit 1
  fi
  
  su - frappe -c "cd /home/frappe/frappe-bench && bench use \"$FRAPPE_SITE_NAME\""
  echo "✅ Cluster schema sync complete!"
else
  echo "ℹ️ Existing cluster initialization detected. Re-linking shared storage path..."
  rm -rf /home/frappe/frappe-bench/sites
  ln -s /storage/sites /home/frappe/frappe-bench/sites
  chown -h frappe:frappe /home/frappe/frappe-bench/sites
fi

# Sync application maps across cluster nodes
echo "frappe" > /storage/sites/apps.txt
if [ -f "/home/frappe/apps.txt" ]; then
  cat /home/frappe/apps.txt >> /storage/sites/apps.txt
fi
chown frappe:frappe /storage/sites/apps.txt 2>/dev/null || true

# Generate process manager properties configurations
SUPERVISOR_CONFIG_FILE="/home/frappe/frappe-bench/config/supervisor.conf"
rm -f "$SUPERVISOR_CONFIG_FILE"
su - frappe -c "cd /home/frappe/frappe-bench && bench setup supervisor --skip-redis"

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

mkdir -p /etc/supervisor/conf.d/
ln -sf "$SUPERVISOR_CONFIG_FILE" /etc/supervisor/conf.d/frappe-bench.conf

echo "✅ Transferring master process orchestration over to Supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
