FROM frappe/bench:v5.27.0

USER root

# 1. Install all system deps (including openssh-server, supervisor & pipx) at build-time:
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git python3-pip pipx python3-dev python3-setuptools python3-venv virtualenv \
      nodejs npm xvfb libfontconfig wkhtmltopdf supervisor openssh-server && \
    npm install -g yarn && \
    rm -rf /var/lib/apt/lists/*

# 2. As 'frappe' user, install bench CLI and honcho via pipx:
USER frappe
RUN pipx ensurepath && \
    pipx install --force frappe-bench && \
    pipx install --force honcho

# 3. Copy your init script in place:
USER root
COPY init.sh /usr/local/bin/init.sh
COPY apps.txt /home/frappe/apps.txt
COPY backup.sh /home/frappe/backup.sh
COPY restore.sh /home/frappe/restore.sh
COPY env.config /home/frappe/env.config

# 4. Correct execution permissions and recursive ownership for the frappe user
RUN chmod +x /usr/local/bin/init.sh 

RUN chown -R frappe:frappe /home/frappe && \
    chmod +x /home/frappe/backup.sh /home/frappe/restore.sh

ENTRYPOINT ["bash", "/usr/local/bin/init.sh"]
