#!/bin/bash
set -e
# For commands run as root in this script, HOME might be /root.
# For commands run via su - frappe, frappe's $HOME will be /home/frappe.
# The path to bench installed by pipx for the frappe user is typically /home/frappe/.local/bin/bench.


# Install OpenSSH Server
apt-get update && apt-get install -y openssh-server

echo "root:${FRAPPE_ADMIN_PASSWORD}" | chpasswd

# Start SSH Service
service ssh start

# Optional: Ensure SSH listens on the correct port if necessary
sed -i 's/#Port 22/Port 22/' /etc/ssh/sshd_config


# Check for MYSQL_ROOT_PASSWORD from docker-compose environment
# Check for FRAPPE_ADMIN_PASSWORD from docker-compose environment
if [ -z "${FRAPPE_ADMIN_PASSWORD}" ]; then
  echo "❌ ERROR: FRAPPE_ADMIN_PASSWORD environment variable is not set for the frappe container."
  echo "Please define it in your .env file and ensure it's passed to the frappe service in docker-compose.yml."
  exit 1
fi

export PATH="/home/frappe/.local/bin:$PATH"

# --- START: Load configuration from env.config ---
ENV_CONFIG_FILE="/home/frappe/env.config"
if [ -f "$ENV_CONFIG_FILE" ]; then
  echo "ℹ️ Loading configuration from $ENV_CONFIG_FILE"
  # Source the file and export its variables
  set -o allexport
  source "$ENV_CONFIG_FILE"
  set +o allexport
else
  echo "⚠️ WARNING: Configuration file $ENV_CONFIG_FILE not found. Using default values."
fi

# Set default values if not provided by env.config or if file doesn't exist
FRAPPE_SITE_NAME=${FRAPPE_SITE_NAME:-"erp.local"}
FRAPPE_INTERNAL_PORT=${FRAPPE_INTERNAL_PORT:-8000} # Default internal port for bench serve
FRAPPE_BRANCH=${FRAPPE_BRANCH:-version-15}
# --- END: Load configuration ---

echo "🚀 Initializing ERPNext for site: $FRAPPE_SITE_NAME on internal port: $FRAPPE_INTERNAL_PORT"

# ensure correct ownership on persistent home
# This needs to be done carefully if /home/frappe is a volume from a previous run by a different UID internally
# Allow errors on the network share path so it won't trigger 'set -e' kill signals
chown -R frappe:frappe /home/frappe || echo "⚠️ Network share ownership warning bypassed safely"

# only do the heavy bench init + site create once
if [ ! -d "/home/frappe/frappe-bench/apps/frappe" ]; then
  echo "🛠️ Installing & configuring bench as user 'frappe'..."
  su - frappe -c "bench init --frappe-branch ${FRAPPE_BRANCH} --skip-redis-config-generation /home/frappe/frappe-bench"

  echo "⚙️ Pointing at your Database Cluster & High-Performance Redis Nodes..."
    su - frappe -c "cd /home/frappe/frappe-bench && \
      bench set-mariadb-host proxysql && \
      bench set-config -g redis_cache 'redis://redis-cache:6379' && \
      bench set-config -g redis_queue 'redis://redis-queue:6379' && \
      bench set-config -g redis_socketio 'redis://redis-queue:6379'"
  
    # HACK: Fixes the missing app definition on secondary nodes using GlusterFS
    echo "frappe" > /home/frappe/frappe-bench/sites/apps.txt
    if [ -f "/home/frappe/apps.txt" ]; then
      cat /home/frappe/apps.txt >> /home/frappe/frappe-bench/sites/apps.txt
    fi
  # FRAPPE_SITE_NAME is now set from env.config or default

  FETCH_CMDS_STRING=""
  INSTALL_CMDS_STRING=""

  if [ -f "$APPS_FILE_PATH" ]; then
    echo "🔎 Reading apps to install from $APPS_FILE_PATH..."
    while IFS= read -r app_name || [ -n "$app_name" ]; do
      app_name_trimmed=$(echo "$app_name" | tr -d '\r' | xargs) # Trim whitespace and carriage returns
      if [ -n "$app_name_trimmed" ]; then # Check if app_name is not empty
        echo "   queuing app '$app_name_trimmed' for fetching and installation."
        # Use the configured FRAPPE_BRANCH when fetching apps to ensure version-15 compatibility.
        FETCH_CMDS_STRING="${FETCH_CMDS_STRING}bench get-app ${app_name_trimmed} --branch ${FRAPPE_BRANCH} && "
        INSTALL_CMDS_STRING="${INSTALL_CMDS_STRING}bench --site \"${FRAPPE_SITE_NAME}\" install-app ${app_name_trimmed} && "
      fi
     Papel done < "$APPS_FILE_PATH"

    # Remove trailing ' && ' if commands were added
    if [ -n "$FETCH_CMDS_STRING" ]; then
      FETCH_CMDS_STRING=${FETCH_CMDS_STRING%% && }
    fi
    if [ -n "$INSTALL_CMDS_STRING" ]; then
      INSTALL_CMDS_STRING=${INSTALL_CMDS_STRING%% && }
    fi
  else
    echo "⚠️ WARNING: Apps file '$APPS_FILE_PATH' not found. No apps will be fetched or installed from it."
  fi

  if [ -n "$FETCH_CMDS_STRING" ]; then
    echo "📦 Fetching apps as user 'frappe'..."
    su - frappe -c "cd /home/frappe/frappe-bench && $FETCH_CMDS_STRING"
  else
    echo "ℹ️ No apps specified to fetch."
  fi

  echo "🌐 Creating site '$FRAPPE_SITE_NAME' on the external Galera/ProxySQL Cluster..."
  SITE_SETUP_COMMANDS="bench new-site \"$FRAPPE_SITE_NAME\" \
    --force \
    --db-host=proxysql \
    --db-port=6033 \
    --mariadb-root-password=${MYSQL_ROOT_PASSWORD} \
    --admin-password=${FRAPPE_ADMIN_PASSWORD}"

  if [ -n "$INSTALL_CMDS_STRING" ]; then
    SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && ${INSTALL_CMDS_STRING}"
  else
    echo "ℹ️ No apps specified from $APPS_FILE_PATH to install on the new site."
  fi

  SITE_SETUP_COMMANDS="${SITE_SETUP_COMMANDS} && \
    bench --site \"$FRAPPE_SITE_NAME\" set-config developer_mode 1 && \
    bench --site \"$FRAPPE_SITE_NAME\" clear-cache"

  su - frappe -c "cd /home/frappe/frappe-bench && $SITE_SETUP_COMMANDS"

  # Set current site for bench commands, ensuring currentsite.txt is created
  su - frappe -c "cd /home/frappe/frappe-bench && bench use \"$FRAPPE_SITE_NAME\""

  echo "✅ Bench setup complete!"
else
  echo "ℹ️ Frappe bench appears to be already initialized. Skipping bench init and site creation."
fi

# Generate a proper Supervisor conf from bench itself,
# then symlink it into /etc so supervisord picks it up
echo "⚙️ Generating Supervisor config as user 'frappe'..."

SUPERVISOR_CONFIG_FILE="/home/frappe/frappe-bench/config/supervisor.conf"

rm -f "$SUPERVISOR_CONFIG_FILE"
# bench setup supervisor will use the site from currentsite.txt (set by 'bench use' above if new bench)
su - frappe -c "cd /home/frappe/frappe-bench && bench setup supervisor --skip-redis"

# --- START: Modification to change Gunicorn to bench serve (with debugging) ---
echo "DEBUG: Supervisor config file BEFORE awk modification ($SUPERVISOR_CONFIG_FILE):"
if [ -f "$SUPERVISOR_CONFIG_FILE" ]; then
    cat "$SUPERVISOR_CONFIG_FILE"
else
    echo "ERROR: $SUPERVISOR_CONFIG_FILE does not exist before awk!"
fi
echo "----------------------------------------------------"

echo "🔄 Modifying Supervisor config to use 'bench serve' for web process..."
NEW_WEB_COMMAND="/home/frappe/.local/bin/bench serve --port ${FRAPPE_INTERNAL_PORT}" # Uses configured port
NEW_WEB_DIRECTORY="/home/frappe/frappe-bench"
TEMP_AWK_OUTPUT_FILE="${SUPERVISOR_CONFIG_FILE}.tmp"

if [ ! -f "$SUPERVISOR_CONFIG_FILE" ]; then
    echo "ERROR: Cannot modify $SUPERVISOR_CONFIG_FILE because it was not generated."
else
    # Using classic awk state machine pattern for robustness
    awk -v cmd="$NEW_WEB_COMMAND" -v dir="$NEW_WEB_DIRECTORY" '
    BEGIN {
        state = 0;
    }
    /\[program:frappe-bench-frappe-web\]/ {
        state = 1;
        print $0;
        next;
    }
    (state == 1 && $0 ~ /^[[:space:]]*\[program:/ && $0 !~ /\[program:frappe-bench-frappe-web\]/) {
        state = 0;
    }
    (state == 1) {
        if ($0 ~ /^command=/) { print "command=" cmd; next; }
        if ($0 ~ /^directory=/) { print "directory=" dir; next; }
        if ($0 ~ /gunicorn/ || $0 ~ /frappe\.app:application/ || $0 ~ /--preload/ || $0 ~ /^-w[[:space:]]+[0-9]+/ || $0 ~ /^-b[[:space:]]+[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+/) {
            print "# (Original gunicorn-related line commented out by script) " $0;
            next;
        }
        print $0;
        next;
    }
    { print $0; }
    ' "$SUPERVISOR_CONFIG_FILE" > "$TEMP_AWK_OUTPUT_FILE"

    awk_exit_status=$?
    if [ $awk_exit_status -eq 0 ]; then
        echo "DEBUG: awk command completed successfully. Moving $TEMP_AWK_OUTPUT_FILE to $SUPERVISOR_CONFIG_FILE"
        mv "$TEMP_AWK_OUTPUT_FILE" "$SUPERVISOR_CONFIG_FILE"
        chown frappe:frappe "$SUPERVISOR_CONFIG_FILE" # Ensure frappe user owns it
        echo "✅ Supervisor config modified for 'bench serve'."
    else
        echo "ERROR: awk command failed with exit status $awk_exit_status. Original supervisor.conf may be unchanged or .tmp file may exist."
        echo "DEBUG: Contents of temp awk output file ($TEMP_AWK_OUTPUT_FILE):"
        if [ -f "$TEMP_AWK_OUTPUT_FILE" ]; then
            cat "$TEMP_AWK_OUTPUT_FILE"; rm "$TEMP_AWK_OUTPUT_FILE";
        else
            echo "DEBUG: Temp awk output file does not exist."
        fi
    fi
fi # End check if SUPERVISOR_CONFIG_FILE exists

echo "DEBUG: Supervisor config file AFTER awk modification attempt ($SUPERVISOR_CONFIG_FILE):"
if [ -f "$SUPERVISOR_CONFIG_FILE" ]; then
    cat "$SUPERVISOR_CONFIG_FILE"
else
    echo "ERROR: $SUPERVISOR_CONFIG_FILE does not exist after awk!"
fi
echo "----------------------------------------------------"
# --- END: Debugging and Modification ---

# Ensure supervisor conf directory exists and symlink the config
mkdir -p /etc/supervisor/conf.d/
ln -sf "$SUPERVISOR_CONFIG_FILE" /etc/supervisor/conf.d/frappe-bench.conf

echo "✅ Starting Supervisor in the foreground…"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
