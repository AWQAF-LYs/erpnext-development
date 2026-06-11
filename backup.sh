#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that returned a non-zero return value.

# --- Configuration & Validation ---
echo "Starting S3 backup process..."
echo "Timestamp: $(date +"%Y-%m-%d %H:%M:%S")"

# These are expected to be set as environment variables in the container
REQUIRED_VARS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_DEFAULT_REGION" "S3_BACKUP_URL" "FRAPPE_SITE_NAME")
for VAR_NAME in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR_NAME}" ]; then
    echo "Error: Environment variable $VAR_NAME is not set. Exiting."
    exit 1
  fi
done

SITE_TO_BACKUP="${FRAPPE_SITE_NAME}" # Use directly from env var
BENCH_DIR="/home/frappe/frappe-bench"
SITES_DIR="${BENCH_DIR}/sites"

# Ensure S3_BACKUP_URL ends with a slash
if [[ "${S3_BACKUP_URL}" != */ ]]; then
  S3_BACKUP_URL="${S3_BACKUP_URL}/"
  echo "Warning: S3_BACKUP_URL did not end with a slash. Appended: ${S3_BACKUP_URL}"
fi

echo "Target site for backup: ${SITE_TO_BACKUP}"
echo "Backup destination: ${S3_BACKUP_URL}"

# --- 1. Check and Install AWS CLI v2 (if run as root) ---
if ! command -v aws &> /dev/null; then
  echo "AWS CLI not found. Attempting to install AWS CLI v2..."
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: AWS CLI installation requires root privileges, but script is not run as root."
    echo "Please install AWS CLI in your Dockerfile or run this script as root."
    exit 1
  fi
  if ! command -v curl &> /dev/null || ! command -v unzip &> /dev/null; then
     echo "curl or unzip not found. Installing them first..."
     apt-get update -y && apt-get install -y curl unzip
  fi
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install # Installs to /usr/local/aws-cli/v2/current/bin/aws and /usr/local/bin/aws
  rm -rf /tmp/awscliv2.zip /tmp/aws
  echo "AWS CLI v2 installed successfully."
else
  echo "AWS CLI found: $(aws --version)"
fi

# --- 2. Configure AWS CLI (uses environment variables automatically) ---
echo "AWS CLI will use credentials and region from environment variables."
# Optional: Increase multipart threshold for potentially large backup files
# aws configure set default.s3.multipart_threshold 64MB
# aws configure set default.s3.multipart_chunksize 16MB

# --- 3. Create Backup with Files ---
# Determine actual backup path based on site or 'all'
CURRENT_BACKUP_PATH=""
if [ "${SITE_TO_BACKUP}" == "all" ]; then
    # For 'all' sites, backups are typically in a common directory or include site configs differently.
    # `bench backup --with-files` when site is 'all' might behave differently.
    # Let's assume we want to back up a specific site defined by FRAPPE_SITE_NAME.
    # If you truly want to back up all sites, the logic to find and upload them needs adjustment.
    # For now, this script is geared towards a single site backup specified by FRAPPE_SITE_NAME.
    # If FRAPPE_SITE_NAME is literally "all", `bench backup --site all` will be run.
    # The location of these "all sites" backups can be less predictable for individual file uploads.
    # A common pattern for "all" is to backup site configs and let individual site backups handle site data.
    # For robust "all" site backup, consider backing up `${SITES_DIR}/common_site_config.json`
    # and then iterating through each site directory found in `${SITES_DIR}` (excluding assets, etc.)
    # and running `bench backup --site <each_site>`.
    # This script will currently try to backup what `bench backup --site ${SITE_TO_BACKUP}` produces.
    # If SITE_TO_BACKUP is 'all', backup files might be in sites/private/backups
    if [ ! -d "${SITES_DIR}/${SITE_TO_BACKUP}" ] && [ "${SITE_TO_BACKUP}" != "all" ]; then
        echo "Error: Site directory ${SITES_DIR}/${SITE_TO_BACKUP} does not exist."
        exit 1
    fi
    TARGET_BACKUP_DIR="${SITES_DIR}/${SITE_TO_BACKUP}/private/backups"
    if [ "${SITE_TO_BACKUP}" == "all" ]; then
      TARGET_BACKUP_DIR="${SITES_DIR}/private/backups" # Common backup location for 'all'
    fi
else
    if [ ! -d "${SITES_DIR}/${SITE_TO_BACKUP}" ]; then
        echo "Error: Site directory ${SITES_DIR}/${SITE_TO_BACKUP} does not exist."
        exit 1
    fi
    TARGET_BACKUP_DIR="${SITES_DIR}/${SITE_TO_BACKUP}/private/backups"
fi

echo "Creating backup for site: ${SITE_TO_BACKUP} with files. Backup directory: ${TARGET_BACKUP_DIR}"
# Ensure target backup directory exists (bench usually creates it)
su - frappe -c "mkdir -p ${TARGET_BACKUP_DIR}"

BACKUP_COMMAND="cd ${BENCH_DIR} && bench --site \"${SITE_TO_BACKUP}\" backup --with-files"
echo "Running backup command as frappe user: ${BACKUP_COMMAND}"

# Capture the output to find the backup filenames if possible, or use find later
# Using a temporary file for output is more robust for multiline output
OUTPUT_FILE=$(mktemp)
if su - frappe -c "${BACKUP_COMMAND}" > "${OUTPUT_FILE}" 2>&1; then
    echo "Backup command seems to have succeeded."
    cat "${OUTPUT_FILE}"
else
    echo "Error during bench backup command:"
    cat "${OUTPUT_FILE}"
    rm "${OUTPUT_FILE}"
    exit 1
fi
BACKUP_OUTPUT=$(cat "${OUTPUT_FILE}")
rm "${OUTPUT_FILE}"


# Find the latest set of backup files. Bench creates multiple files with a common timestamp prefix.
# e.g., YYYYMMDD_HHMMSS-sitename-database.sql.gz, YYYYMMDD_HHMMSS-sitename-private-files.tar.gz etc.
LATEST_SQL_BACKUP=$(su - frappe -c "find ${TARGET_BACKUP_DIR} -name '*-database.sql.gz' -print0 | xargs -0 ls -t | head -n 1")

if [ -z "${LATEST_SQL_BACKUP}" ]; then
  echo "Error: No SQL backup file found in ${TARGET_BACKUP_DIR} after running bench backup."
  echo "Backup output was:"
  echo "${BACKUP_OUTPUT}"
  exit 1
fi
echo "Latest SQL backup file found: ${LATEST_SQL_BACKUP}"

BACKUP_BASENAME=$(basename "${LATEST_SQL_BACKUP}")
# Extracts YYYYMMDD_HHMMSS-sitename (or just YYYYMMDD_HHMMSS if site is 'all' and bench names it that way)
BACKUP_PREFIX=$(echo "${BACKUP_BASENAME}" | sed 's/-database\.sql\.gz$//')
echo "Identified backup prefix: ${BACKUP_PREFIX}"

# --- 4. Upload Files to S3 ---
# Create a "folder" in S3 using the site name and the backup prefix
S3_SITE_PREFIX_PATH="${S3_BACKUP_URL}${SITE_TO_BACKUP}/${BACKUP_PREFIX}"
echo "Uploading backup files for prefix ${BACKUP_PREFIX} to S3 path: ${S3_SITE_PREFIX_PATH}/"

# List files to upload that match the prefix from the backup operation
# This assumes `su - frappe` can read these files, which it should since it created them.
# The `aws s3 cp` command will be run by the user executing this script (e.g. root).
UPLOAD_SUCCESSFUL=true
su - frappe -c "find ${TARGET_BACKUP_DIR} -name '${BACKUP_PREFIX}*' -type f" | while read -r FILE_PATH; do
  if [ -f "${FILE_PATH}" ]; then
    FILENAME=$(basename "${FILE_PATH}")
    echo "Uploading ${FILE_PATH} to ${S3_SITE_PREFIX_PATH}/${FILENAME} ..."
    if aws s3 cp "${FILE_PATH}" "${S3_SITE_PREFIX_PATH}/${FILENAME}"; then
      echo "Successfully uploaded ${FILENAME}."
    else
      echo "Error uploading ${FILENAME}."
      UPLOAD_SUCCESSFUL=false
    fi
  else
    echo "Warning: File ${FILE_PATH} not found for upload ( Tämä ei saisi tapahtua)."
  fi
done

if [ "${UPLOAD_SUCCESSFUL}" = true ]; then
  echo "All backup files for prefix ${BACKUP_PREFIX} uploaded successfully."
else
  echo "One or more files failed to upload for prefix ${BACKUP_PREFIX}."
  exit 1 # Or handle more gracefully
fi

echo "Backup and S3 upload process finished for ${SITE_TO_BACKUP}."

# Optional: Cleanup old local backups (e.g., older than 7 days)
CLEANUP_DAYS=7
echo "Cleaning up local backup files older than ${CLEANUP_DAYS} days in ${TARGET_BACKUP_DIR}..."
su - frappe -c "find ${TARGET_BACKUP_DIR} -name '*-database.sql.gz' -mtime +${CLEANUP_DAYS} -print -delete"
su - frappe -c "find ${TARGET_BACKUP_DIR} -name '*-private-files.tar.gz' -mtime +${CLEANUP_DAYS} -print -delete"
su - frappe -c "find ${TARGET_BACKUP_DIR} -name '*-public-files.tar.gz' -mtime +${CLEANUP_DAYS} -print -delete"
su - frappe -c "find ${TARGET_BACKUP_DIR} -name '*-site_config_backup.json' -mtime +${CLEANUP_DAYS} -print -delete"
echo "Local cleanup finished."

exit 0
