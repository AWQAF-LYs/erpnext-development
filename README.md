# <a href="https://frappe.doc.moomken.org" target="_blank" rel="noopener noreferrer">Online Documentation</a>

# Custom ERPNext Docker Deployment

This project provides a Dockerized setup for ERPNext, allowing for custom app installations, configurable site names, and ports.

## Prerequisites

* Docker Engine
* Docker Compose

## Directory Structure
.
├── Dockerfile              # Defines the Docker image for the Frappe/ERPNext application
├── docker-compose.yml      # Defines the multi-container Docker application (ERPNext, MariaDB, Redis)
├── init.sh                 # Initialization script run when the ERPNext container starts
├── apps.txt                # List of Frappe apps to install (one per line)
├── backup.sh               # Placeholder script for backup commands (copied into the container)
├── env.config              # Configuration for site name and internal port (used by init.sh)
├── .env                    # Environment variables for docker-compose (ports, etc.)
└── README.md               # This file

## Configuration

Before building and running, you might want to customize the following configuration files:

1.  **`.env`** (in the project root, for `docker-compose`)
    * Controls port mappings from your host machine to the ERPNext container.
    * Example:
        ```env
        # Host port to access ERPNext
        FRAPPE_HOST_PORT=8000
        # Container port (MUST match FRAPPE_INTERNAL_PORT in env.config)
        FRAPPE_CONTAINER_PORT=8000

        # Host port for SocketIO
        SOCKETIO_HOST_PORT=9000
        # Container port for SocketIO
        SOCKETIO_CONTAINER_PORT=9000
        ```

2.  **`env.config`** (in the project root, copied into the container)
    * Controls settings *inside* the ERPNext container.
    * Example:
        ```ini
        FRAPPE_SITE_NAME=erpnext.localhost
        FRAPPE_INTERNAL_PORT=8000
        ```
    * `FRAPPE_SITE_NAME`: The site name that will be created (e.g., `mycompany.erp.local`).
    * `FRAPPE_INTERNAL_PORT`: The port on which `bench serve` will listen inside the container. **This MUST match `FRAPPE_CONTAINER_PORT` in the `.env` file.**

3.  **`apps.txt`** (in the project root)
    * List the Frappe apps you want to install during the initial setup, one app name per line.
    * Example:
        ```
        erpnext
        # builder
        # hrms
        # Add other custom apps here
        ```

4.  **`backup.sh`** (in the project root)
    * This script is copied into the container at `/home/frappe/backup.sh`.
    * You can place your custom backup commands here. The `init.sh` script does not run it automatically; you would need to execute it manually (e.g., via `docker exec`) or set up a cron job inside the container.
    * Example:
        ```bash
        #!/bin/bash
        echo "Executing backup script..."
        # Ensure env.config is sourced if needed for FRAPPE_SITE_NAME
        # if [ -f "/home/frappe/env.config" ]; then source "/home/frappe/env.config"; fi
        # bench --site "${FRAPPE_SITE_NAME:-all}" backup --with-files >> /home/frappe/frappe-bench/logs/backup.log 2>&1
        echo "Backup script finished."
        ```

## How to Build and Run

1.  **Navigate to the project directory:**
    ```bash
    cd /path/to/your/project
    ```

2.  **Customize configuration files** (`.env`, `env.config`, `apps.txt`) as needed.

3.  **Build the Docker images:**
    ```bash
    docker-compose build
    ```

4.  **Start the services:**
    ```bash
    docker-compose up -d
    ```
    The `-d` flag runs the containers in detached mode.

5.  **Initial Setup:** The first time you run `docker-compose up`, the `init.sh` script will:
    * Initialize `frappe-bench`.
    * Set up database and Redis connections.
    * Fetch apps listed in `apps.txt`.
    * Create a new site with the name specified in `env.config` (or default `erpnext.local`).
    * Install the fetched apps on the new site.
    * Configure Supervisor to use `bench serve` with the specified internal port.
    This process can take several minutes. You can monitor the logs using:
    ```bash
    docker-compose logs -f frappe
    ```

## Accessing ERPNext

Once the setup is complete, you should be able to access ERPNext in your web browser at:
`http://localhost:<FRAPPE_HOST_PORT>`
(e.g., `http://localhost:8000` if `FRAPPE_HOST_PORT=8000` in your `.env` file).

The default admin password (if not changed during setup or via `init.sh`) is `admin` (as set in `init.sh` during `bench new-site`). It's highly recommended to change this immediately after first login.

## Persistent Data

* ERPNext site data (files, private files) and bench configuration are stored in the `frappe-data` Docker volume, which persists even if you stop and remove the containers (but not if you remove the volume itself).
* MariaDB database data is stored in the `mariadb-data` Docker volume.

To remove containers AND volumes (this will delete your data):
```bash
docker-compose down -v

Customizing Further
Adding Apps: Modify apps.txt and rebuild the frappe image (docker-compose build frappe). Then restart (docker-compose up -d). Note that init.sh currently only installs apps from apps.txt during the very first site creation. To add apps to an existing site, you might need todocker execinto the container and usebenchcommands manually or enhanceinit.sh`.
Backup Script: Edit backup.sh with your desired backup logic.
Troubleshooting
Check container logs:
Bash

docker-compose logs frappe
docker-compose logs mariadb
docker-compose logs redis
Ensure ports specified in .env and env.config are consistent and not already in use on your host.
