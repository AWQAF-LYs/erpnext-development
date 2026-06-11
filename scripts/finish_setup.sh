#!/bin/bash
set -euo pipefail

# Load env.config if present
if [ -f /home/frappe/env.config ]; then
  set -o allexport
  source /home/frappe/env.config
  set +o allexport
fi

cd /home/frappe/frappe-bench || exit 1

# Fetch apps
su - frappe -c "bench get-app erpnext --branch ${FRAPPE_BRANCH} || true"
su - frappe -c "bench get-app hrms --branch ${FRAPPE_BRANCH} || true"

# Install apps on site
su - frappe -c "bench --site \"${FRAPPE_SITE_NAME}\" install-app erpnext || true"
su - frappe -c "bench --site \"${FRAPPE_SITE_NAME}\" install-app hrms || true"

# Build and restart
su - frappe -c "bench build || true"
su - frappe -c "bench restart || true"

exit 0
