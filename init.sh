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
    echo "⚠️ WARNING: MYSQL_ROOT_PASSWORD environment variable is empty! This will cause database initialization to prompt and fail."
fi

echo "🚀 Site Configuration Target: $FRAPPE_SITE_NAME on Port: $FRAPPE_INTERNAL_PORT"

# Create a physical supervisorctl mock binary to safely intercept Python subprocess hooks
mkdir -p /home/frappe/.local/bin
cat << 'EOF' > /home/frappe/.local/bin/supervisorctl
#!/bin/sh
echo "Muted Supervisor Hook (${*})"
exit 0
EOF
chmod +x /home/frappe/.local/bin/supervisorctl
chown frappe:frappe /home/frappe/.local/bin/supervisorctl

# FIX: Ensure both sites AND logs persistent network volumes exist with wide open clearances
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
  bench set-mariadb-host proxysql
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
