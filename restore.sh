#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that returned a non-zero return value.

# --- Script Configuration ---
EXPECTED_ARGS_MIN=2 # e.g., -name backup_name
BACKUP_NAME_ARG=""
NON_INTERACTIVE_FLAG=false

# --- Helper Functions ---
log_info() {
    echo "[INFO] $(date +"%Y-%m-%d %H:%M:%S") - $1"
}

log_error() {
    echo "[ERROR] $(date +"%Y-%m-%d %H:%M:%S") - $1" >&2
}

usage() {
    echo "Usage: $0 -name <backup_folder_name_on_s3> [-y]"
    echo "  -name <backup_folder_name_on_s3> : The unique identifier of the backup set on S3 (e.g., YYYYMMDD_HHMMSS-sitename)."
    echo "  -y                               : Optional. Confirms operations automatically (non-interactive mode)."
    exit 1
}

# --- Argument Parsing ---
if [ "$#" -lt ${EXPECTED_ARGS_MIN} ]; then
    usage
fi

while (( "$#" )); do
  case "$1" in
    -name|--name)
      if [ -n "$2" ] && [[ $2 != -* ]]; then
        BACKUP_NAME_ARG="$2"
        shift 2
      else
        log_error "Argument for $1 is missing or invalid."
        usage
      fi
      ;;
    -y|--yes)
      NON_INTERACTIVE_FLAG=true
      shift
      ;;
    *) # unsupported flags
      log_error "Unsupported flag $1."
      usage
      ;;
  esac
done

if [ -z "$BACKUP_NAME_ARG" ]; then
    log_error "Backup name not provided."
    usage
fi

log_info "Starting S3 restore process..."
log_info "Backup identifier to restore: ${BACKUP_NAME_ARG}"
if [ "$NON_INTERACTIVE_FLAG" = true ]; then
    log_info "Non-interactive mode enabled (-y)."
fi

# --- Configuration & Validation ---
# These are expected to be set as environment variables
REQUIRED_VARS=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_DEFAULT_REGION" "S3_BACKUP_URL" "FRAPPE_SITE_NAME")
for VAR_NAME in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR_NAME}" ]; then
    log_error "Environment variable $VAR_NAME is not set. Exiting."
    exit 1
  fi
done

FRAPPE_SITE_NAME="${FRAPPE_SITE_NAME}" # Use directly from env var
BENCH_DIR="/home/frappe/frappe-bench" # Standard Frappe bench directory
SITES_DIR="${BENCH_DIR}/sites"
S3_BACKUP_URL_RAW="${S3_BACKUP_URL}"

# Ensure FRAPPE_SITE_NAME is not 'all' for restore
if [ "${FRAPPE_SITE_NAME}" == "all" ]; then
  log_error "FRAPPE_SITE_NAME cannot be 'all' for a restore operation."
  log_error "Please set FRAPPE_SITE_NAME to a specific site name in your environment."
  exit 1
fi

# Ensure S3_BACKUP_URL ends with a slash
if [[ "${S3_BACKUP_URL_RAW}" != */ ]]; then
  S3_BACKUP_URL_RAW="${S3_BACKUP_URL_RAW}/"
  log_info "Appended slash to S3_BACKUP_URL: ${S3_BACKUP_URL_RAW}"
fi

# S3 path for the specific backup folder. Assumes backups are stored under <S3_BACKUP_URL>/<SITE_NAME>/<BACKUP_IDENTIFIER>/
S3_SOURCE_BASE_PATH="${S3_BACKUP_URL_RAW}${FRAPPE_SITE_NAME}/${BACKUP_NAME_ARG}"
if [[ "${S3_SOURCE_BASE_PATH}" != */ ]]; then
  S3_SOURCE_BASE_PATH="${S3_SOURCE_BASE_PATH}/"
fi

log_info "Target site for restore: ${FRAPPE_SITE_NAME}"
log_info "Bench directory: ${BENCH_DIR}"
log_info "S3 Source Path for backup files: ${S3_SOURCE_BASE_PATH}"

# --- 1. Check and Install AWS CLI v2 (if run as root) ---
if ! command -v aws &> /dev/null; then
  log_info "AWS CLI not found. Attempting to install AWS CLI v2..."
  if [ "$(id -u)" -ne 0 ]; then
    log_error "AWS CLI installation requires root privileges, but script is not run as root."
    log_error "Please install AWS CLI in your Dockerfile or run this script as root."
    exit 1
  fi
  if ! command -v curl &> /dev/null || ! command -v unzip &> /dev/null; then
    log_info "curl or unzip not found. Installing them first..."
    apt-get update -y && apt-get install -y curl unzip
  fi
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install # Installs to /usr/local/aws-cli/v2/current/bin/aws and /usr/local/bin/aws
  rm -rf /tmp/awscliv2.zip /tmp/aws
  log_info "AWS CLI v2 installed successfully."
else
  log_info "AWS CLI found: $(aws --version)"
fi

# --- 2. Configure AWS CLI (uses environment variables automatically) ---
log_info "AWS CLI will use credentials and region from environment variables."

# --- 3. Download Backup Files from S3 ---
LOCAL_RESTORE_DIR=$(mktemp -d -t frappe_restore_${BACKUP_NAME_ARG}_XXXXXXXXXX)
log_info "Created temporary local directory for downloads: ${LOCAL_RESTORE_DIR}"

# Define expected S3 file names based on the backup prefix (BACKUP_NAME_ARG)
SQL_FILE_S3_NAME="${BACKUP_NAME_ARG}-database.sql.gz"
PRIVATE_FILES_S3_NAME="${BACKUP_NAME_ARG}-private-files.tar.gz"
PUBLIC_FILES_S3_NAME="${BACKUP_NAME_ARG}-public-files.tar.gz"
CONFIG_S3_NAME="${BACKUP_NAME_ARG}-site_config_backup.json"

# Paths for downloaded files
SQL_FILE_LOCAL_PATH="${LOCAL_RESTORE_DIR}/${SQL_FILE_S3_NAME}"
PRIVATE_FILES_LOCAL_PATH="" # Will be set if download is successful
PUBLIC_FILES_LOCAL_PATH=""  # Will be set if download is successful
CONFIG_FILE_LOCAL_PATH=""   # Will be set if download is successful

# Download SQL file (mandatory)
log_info "Downloading SQL backup: ${SQL_FILE_S3_NAME} from ${S3_SOURCE_BASE_PATH}${SQL_FILE_S3_NAME}"
if ! aws s3 cp "${S3_SOURCE_BASE_PATH}${SQL_FILE_S3_NAME}" "${SQL_FILE_LOCAL_PATH}" --only-show-errors; then
    log_error "Failed to download SQL backup file ${SQL_FILE_S3_NAME} from S3."
    log_error "Please ensure the backup name ('${BACKUP_NAME_ARG}') and S3 path ('${S3_SOURCE_BASE_PATH}') are correct and the file exists."
    rm -rf "${LOCAL_RESTORE_DIR}"
    exit 1
fi
if [ ! -s "${SQL_FILE_LOCAL_PATH}" ]; then # -s checks if file exists and is not empty
    log_error "Downloaded SQL backup file ${SQL_FILE_LOCAL_PATH} is empty or does not exist."
    rm -rf "${LOCAL_RESTORE_DIR}"
    exit 1
fi
log_info "Successfully downloaded SQL backup to ${SQL_FILE_LOCAL_PATH}."

# Download private files (optional)
log_info "Attempting to download private files: ${PRIVATE_FILES_S3_NAME}..."
TEMP_PRIVATE_FILES_LOCAL_PATH="${LOCAL_RESTORE_DIR}/${PRIVATE_FILES_S3_NAME}"
if aws s3 cp "${S3_SOURCE_BASE_PATH}${PRIVATE_FILES_S3_NAME}" "${TEMP_PRIVATE_FILES_LOCAL_PATH}" --only-show-errors; then
    if [ -s "${TEMP_PRIVATE_FILES_LOCAL_PATH}" ]; then
        PRIVATE_FILES_LOCAL_PATH="${TEMP_PRIVATE_FILES_LOCAL_PATH}"
        log_info "Successfully downloaded private files to ${PRIVATE_FILES_LOCAL_PATH}."
    else
        log_info "Private files backup ${PRIVATE_FILES_S3_NAME} downloaded but is empty. Proceeding without it."
    fi
else
    log_info "Private files backup ${PRIVATE_FILES_S3_NAME} not found in S3 or failed to download. Proceeding without it."
fi

# Download public files (optional)
log_info "Attempting to download public files: ${PUBLIC_FILES_S3_NAME}..."
TEMP_PUBLIC_FILES_LOCAL_PATH="${LOCAL_RESTORE_DIR}/${PUBLIC_FILES_S3_NAME}"
if aws s3 cp "${S3_SOURCE_BASE_PATH}${PUBLIC_FILES_S3_NAME}" "${TEMP_PUBLIC_FILES_LOCAL_PATH}" --only-show-errors; then
    if [ -s "${TEMP_PUBLIC_FILES_LOCAL_PATH}" ]; then
        PUBLIC_FILES_LOCAL_PATH="${TEMP_PUBLIC_FILES_LOCAL_PATH}"
        log_info "Successfully downloaded public files to ${PUBLIC_FILES_LOCAL_PATH}."
    else
        log_info "Public files backup ${PUBLIC_FILES_S3_NAME} downloaded but is empty. Proceeding without it."
    fi
else
    log_info "Public files backup ${PUBLIC_FILES_S3_NAME} not found in S3 or failed to download. Proceeding without it."
fi

# Download site config backup (optional, bench restore usually picks it up if in the same dir as SQL)
log_info "Attempting to download site config backup: ${CONFIG_S3_NAME}..."
TEMP_CONFIG_FILE_LOCAL_PATH="${LOCAL_RESTORE_DIR}/${CONFIG_S3_NAME}"
if aws s3 cp "${S3_SOURCE_BASE_PATH}${CONFIG_S3_NAME}" "${TEMP_CONFIG_FILE_LOCAL_PATH}" --only-show-errors; then
    if [ -s "${TEMP_CONFIG_FILE_LOCAL_PATH}" ]; then
        CONFIG_FILE_LOCAL_PATH="${TEMP_CONFIG_FILE_LOCAL_PATH}"
        log_info "Successfully downloaded site config backup to ${CONFIG_FILE_LOCAL_PATH}."
    else
        log_info "Site config backup ${CONFIG_S3_NAME} downloaded but is empty."
    fi
else
    log_info "Site config backup ${CONFIG_S3_NAME} not found in S3 or failed to download."
fi

# --- 4. Perform Restore using Bench ---
log_info "Preparing to restore site: ${FRAPPE_SITE_NAME} using backup SQL file: ${SQL_FILE_LOCAL_PATH}"

# Construct the bench restore command
# Note: The user running this script (e.g. root) needs passwordless su to frappe,
# or you need to run this script as the frappe user (adjust AWS CLI install then).
# Assuming su - frappe -c works as in the backup script.

RESTORE_CMD_PARTS=()
RESTORE_CMD_PARTS+=("cd ${BENCH_DIR} && bench")
RESTORE_CMD_PARTS+=("--site \"${FRAPPE_SITE_NAME}\" restore")
RESTORE_CMD_PARTS+=("\"${SQL_FILE_LOCAL_PATH}\"") # Path to SQL file

if [ "$NON_INTERACTIVE_FLAG" = true ]; then
    RESTORE_CMD_PARTS+=("--force")
fi

if [ -n "${PRIVATE_FILES_LOCAL_PATH}" ] && [ -s "${PRIVATE_FILES_LOCAL_PATH}" ]; then
    RESTORE_CMD_PARTS+=("--with-private-files \"${PRIVATE_FILES_LOCAL_PATH}\"")
    log_info "Will restore with private files: ${PRIVATE_FILES_LOCAL_PATH}"
fi

if [ -n "${PUBLIC_FILES_LOCAL_PATH}" ] && [ -s "${PUBLIC_FILES_LOCAL_PATH}" ]; then
    RESTORE_CMD_PARTS+=("--with-public-files \"${PUBLIC_FILES_LOCAL_PATH}\"")
    log_info "Will restore with public files: ${PUBLIC_FILES_LOCAL_PATH}"
fi
# Site config is typically restored automatically if the *-site_config_backup.json
# is in the same directory as the SQL file when `bench restore` is run.

FULL_RESTORE_COMMAND="${RESTORE_CMD_PARTS[*]}"
log_info "Executing restore command as frappe user: ${FULL_RESTORE_COMMAND}"

# Prompt for confirmation if not in non-interactive mode
if [ "$NON_INTERACTIVE_FLAG" = false ]; then
    echo ""
    echo "You are about to restore site '${FRAPPE_SITE_NAME}' using backup files from S3 identifier '${BACKUP_NAME_ARG}'."
    echo "This will overwrite existing data for site '${FRAPPE_SITE_NAME}'."
    read -p "Are you sure you want to continue? (yes/No): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        log_info "Restore cancelled by user."
        rm -rf "${LOCAL_RESTORE_DIR}"
        exit 0
    fi
fi

OUTPUT_FILE=$(mktemp -t frappe_restore_output_XXXXXXXXXX)
# Ensure the frappe user has access to the downloaded files in LOCAL_RESTORE_DIR
# If script is run as root, LOCAL_RESTORE_DIR and its contents might need permissions adjustment
# However, mktemp usually creates it with user-only access. `su - frappe` might not see it.
# A safer approach for `su` is to ensure frappe user can read or copy files to its own space.
# For simplicity here, we assume `su - frappe` can access the path if the parent temp dir allows.
# Or, more robustly, copy files to a frappe-owned directory before restore.
# Let's try direct access first, as `bench backup` also writes to dirs that `su - frappe` created.

# Adjust permissions on the temporary directory so frappe user can read files.
chmod -R 755 "${LOCAL_RESTORE_DIR}" # Or more specifically, ensure frappe user can read.

log_info "Attempting restore operation..."
if su - frappe -c "${FULL_RESTORE_COMMAND}" > "${OUTPUT_FILE}" 2>&1; then
    log_info "Bench restore command seems to have succeeded."
    cat "${OUTPUT_FILE}"
else
    log_error "Error during bench restore command execution."
    log_error "Output from bench restore:"
    cat "${OUTPUT_FILE}"
    log_error "Downloaded backup files are kept in ${LOCAL_RESTORE_DIR} for inspection."
    # Do not delete LOCAL_RESTORE_DIR on failure to allow inspection
    rm -f "${OUTPUT_FILE}"
    exit 1
fi
rm -f "${OUTPUT_FILE}"

# --- 5. Cleanup ---
log_info "Cleaning up temporary local download directory: ${LOCAL_RESTORE_DIR}"
rm -rf "${LOCAL_RESTORE_DIR}"

log_info "S3 restore process finished successfully for site ${FRAPPE_SITE_NAME} using backup ${BACKUP_NAME_ARG}."
exit 0
