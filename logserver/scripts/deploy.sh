#!/bin/bash
# Deploys the logserver to the nasbox.
#
# Run from the repo root on your laptop:
#   bash logserver/scripts/deploy.sh
#
# Before first run, edit /etc/systemd/system/logserver.service on the Pi
# and set LOG_TOKEN to a strong random string.

set -euo pipefail

PI="nakomis@nasbox.local"
REMOTE_DIR="/home/nakomis"

echo "Copying logserver source..."
scp logserver/src/main.py "${PI}:${REMOTE_DIR}/logserver.py"
scp logserver/src/requirements.txt "${PI}:${REMOTE_DIR}/logserver-requirements.txt"

echo "Installing Python dependencies..."
ssh "${PI}" "pip3 install --quiet -r ${REMOTE_DIR}/logserver-requirements.txt"

# Create the systemd service if it doesn't exist yet
ssh "${PI}" bash << 'REMOTE'
if [ ! -f /etc/systemd/system/logserver.service ]; then
    echo "Creating systemd service..."
    sudo tee /etc/systemd/system/logserver.service > /dev/null << 'EOF'
[Unit]
Description=ESP32 log upload server
After=network.target mnt-logs.mount

[Service]
User=nakomis
ExecStart=/usr/bin/python3 -m uvicorn logserver:app --host 127.0.0.1 --port 8765
WorkingDirectory=/home/nakomis
Environment=LOG_TOKEN=change-me-to-something-long
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable logserver
    echo ""
    echo "IMPORTANT: Edit /etc/systemd/system/logserver.service and set LOG_TOKEN"
    echo "           before starting the service, then run: sudo systemctl start logserver"
else
    echo "Restarting logserver..."
    sudo systemctl daemon-reload
    sudo systemctl restart logserver
    sudo systemctl status logserver --no-pager
fi
REMOTE

echo "Done."
