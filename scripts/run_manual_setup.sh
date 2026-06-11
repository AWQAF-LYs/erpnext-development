#!/bin/bash
set -euo pipefail

echo "Starting manual setup inside container..."

su - frappe -c 'bash -lc "if [ -f /home/frappe/env.config ]; then set -o allexport; source /home/frappe/env.config; set +o allexport; fi; \
cd /home/frappe/frappe-bench || exit 1; \
echo \"Fetching apps (erpnext, hrms)...\"; \
bench get-app erpnext --branch ${FRAPPE_BRANCH} || true; \
bench get-app hrms --branch ${FRAPPE_BRANCH} || true; \
echo \"Installing apps on site ${FRAPPE_SITE_NAME}...\"; \
bench --site \"${FRAPPE_SITE_NAME}\" install-app erpnext || true; \
bench --site \"${FRAPPE_SITE_NAME}\" install-app hrms || true; \
echo \"Building assets...\"; \
bench build || true; \
echo \"Restarting bench processes...\"; \
bench restart || true"'

echo "Manual setup script finished."
