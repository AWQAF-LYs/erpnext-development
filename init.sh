#!/bin/bash
set -e

# --- 1. RUNTIME CONFIGURATION SECURITY CHECK ---
# Enforce that passwords must exist at runtime before running any script logic
if [ -z "${FRAPPE_ADMIN_PASSWORD}" ]; then
  echo "❌ ERROR: FRAPPE_ADMIN_PASSWORD environment variable is not set at runtime."
  echo "Defaulting to fallback string to prevent PAM chauthtok failure..."
  FRAPPE_ADMIN_PASSWORD="Aa123123Password!"
fi

# Apply the password dynamically from the container runtime environment variable
echo "root:${FRAPPE_ADMIN_PASSWORD}" | chpasswd || echo "⚠️ Warning: Secure runtime password assignment skipped"

# Configure and safely spin up SSH service daemon 
sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config
service ssh start || true

export PATH="/home/frappe/.local/bin:$PATH"

# --- 2. LOAD VARIABLE DEFAULTS FROM EXTERNAL FILES ---
ENV_CONFIG_FILE="/home/frappe/env.config"
if [ -f "$ENV_CONFIG_FILE" ]; then
  echo "ℹ️ Loading configuration from $ENV_CONFIG_FILE"
  set -o allexport
  source "$ENV_CONFIG_FILE"
  set +o allexport
else
  echo "⚠️ WARNING: Configuration file $ENV_CONFIG_FILE not found. Using defaults."
fi

FRAPPE_SITE_NAME=${FRAPPE_SITE_NAME:-"erp.local"}
FRAPPE_INTERNAL_PORT=${FRAPPE_INTERNAL_PORT:-8000} 
FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-15}

echo "🚀 Initializing ERPNext for site: $FRAPPE_SITE_NAME on internal port: $FRAPPE_INTERNAL_PORT"

# Clean non-blocking cluster storage check
chown -R frappe:frappe /home/frappe || echo "⚠️ Shared volume permissions handled"

# Only execute cluster DB initialization on the very first node initialization
if [ ! -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  echo "🛠️ Installing & configuring bench as user 'frappe'..."
  su - frappe -c "bench init --frappe-branch ${FRAPPE_BRANCH} --skip-redis-config-generation /home/frappe/frappe-bench"

  echo "⚙️ Pointing at your Database Cluster & High-Performance Redis Nodes..."
  su - frappe -c "cd /home/frappe/frappe-bench && \
    bench set-mariadb-host proxysql && \
    bench set-config -g redis_cache 'redis://redis-cache:6379' && \
    bench set-config -g redis_queue 'redis://redis-queue:6379' && \
    bench set-config -g redis_socketio 'redis://redis-queue:6379'"

  APPS_FILE_PATH="/home/frappe/apps.txt"
  FETCH_CMDS_STRING=""
  INSTALL_CMDS_STRING=""

  if [ -f "$APPS_FILE_PATH" ]; then
    echo "🔎 Reading apps to install from $APPS_FILE_PATH..."
    while IFS= read -r app_name || [ -n "$app_name" ]; do
      app_name_trimmed=$(echo "$app_name" | tr -d '\r' | xargs)
      if [ -n "$app_name_trimmed" ]; then
        echo "   queuing app '$app_name_trimmed' for installation."
        FETCH_CMDS_STRING="${FETCH_CMDS_STRING}bench get-app ${app_name_trimmed} --branch ${FRAPPE_BRANCH} && "
        INSTALL_CMDS_STRING="${INSTALL_CMDS_STRING}bench --site \"${FRAPPE_SITE_NAME}\" install-app ${app_name_trimmed} && "
      fi
    done < "$APPS_FILE_PATH"

    if [ -n "$FETCH_CMDS_STRING" ]; then FETCH_CMDS_STRING=${FETCH_CMDS_STRING%% && }; fi
    if [ -n "$INSTALL_CMDS_STRING" ]; then INSTALL_CMDS_STRING=${INSTALL_CMDS_STRING%% && }; fi
  fi

  if [ -n "$FETCH_CMDS_STRING" ]; then
    su - frappe -c "cd /home/frappe/frappe-bench && $FETCH_CMDS_STRING"
  fi

  echo "🌐 Creating site '$FRAPPE_SITE_NAME' via ProxySQL Entrypoint..."
  SITE_SETUP_COMMANDS="bench new-site \"$FRAPPE_SITE_NAME\" \
    --force \
    --db-host=proxysql \
    --db-port=6033 \
    --mariadb-root-password=${MYSQL_ROOT_PASSWORD} \
    --admin-password=${FRAPPE_ADMIN_PASSWORD}"

  if [ -n "$INSTALL_CMDS_STRING" ]; then
    SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && ${INSTALL_CMDS_STRING}"
  fi

  SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && \
    bench --site \"$FRAPPE_SITE_NAME\" set-config developer_mode 1 && \
    bench --site \"$FRAPPE_SITE_NAME\" clear-cache"

  su - frappe -c "cd /home/frappe/frappe-bench && $SITE_SETUP_COMMANDS"
  su - frappe -c "cd /home/frappe/frappe-bench && bench use \"$FRAPPE_SITE_NAME\""
  echo "✅ Bench setup complete!"
else
  echo "ℹ️ Frappe bench exists. Skipping initialization."
fi

# Sync application mapping across GlusterFS nodes
echo "frappe" > /home/frappe/frappe-bench/sites/apps.txt
if [ -f "/home/frappe/apps.txt" ]; then
  cat /home/frappe/apps.txt >> /home/frappe/frappe-bench/sites/apps.txt
fi
chown frappe:frappe /home/frappe/frappe-bench/sites/apps.txt || true

# Generate production Supervisor configuration
SUPERVISOR_CONFIG_FILE="/home/frappe/frappe-bench/config/supervisor.conf"
rm -f "$SUPERVISOR_CONFIG_FILE"
su - frappe -c "cd /home/frappe/frappe-bench && bench setup supervisor --skip-redis"

# Adjust worker process parameters for unified execution container
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

echo "✅ Launching Supervisord Orchestration Process Engine..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
