#!/bin/bash
# Deploys the logserver to the nasbox.
#
# Run from the repo root on your laptop:
#   bash logserver/scripts/deploy.sh

set -euo pipefail

PI="nakomis@nasbox.local"
REMOTE_DIR="/home/nakomis"

echo "Copying logserver source..."
scp logserver/src/main.py "${PI}:${REMOTE_DIR}/logserver.py"
scp logserver/src/requirements.txt "${PI}:${REMOTE_DIR}/logserver-requirements.txt"

echo "Setting up Python venv and installing dependencies..."
ssh "${PI}" bash << 'REMOTE'
set -euo pipefail
VENV="/home/nakomis/logserver-venv"
if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet -r /home/nakomis/logserver-requirements.txt
REMOTE

ssh "${PI}" bash << 'REMOTE'
set -euo pipefail

SERVICE=/etc/systemd/system/logserver.service
LOG_DIR=/var/log/logserver

# Create log directory if needed
sudo mkdir -p "$LOG_DIR"
sudo chown nakomis:nakomis "$LOG_DIR"

if [ ! -f "$SERVICE" ]; then
    echo "Creating systemd service..."
    # Generate a random LOG_TOKEN on first install
    LOG_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    sudo tee "$SERVICE" > /dev/null << EOF
[Unit]
Description=ESP32 log upload server
After=network.target

[Service]
User=nakomis
ExecStart=/home/nakomis/logserver-venv/bin/uvicorn logserver:app --host 127.0.0.1 --port 8765
WorkingDirectory=/home/nakomis
Environment=LOG_TOKEN=${LOG_TOKEN}
Environment=LOG_DIR=/var/log/logserver
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable logserver
    sudo systemctl start logserver
    echo ""
    echo "LOG_TOKEN for this installation:"
    echo "  ${LOG_TOKEN}"
    echo ""
    echo "Save this — clients need it as their Bearer token."
else
    echo "Restarting logserver..."
    sudo systemctl daemon-reload
    sudo systemctl restart logserver
fi

sudo systemctl status logserver --no-pager
REMOTE

echo "Done."
