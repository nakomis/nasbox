# Log Server — Server Side

A minimal FastAPI service running on the nasbox that accepts log file uploads from ESP32 devices over HTTP. Logs are written to `/mnt/logs/{device_name}/` and are readable from laptops via the `[logs]` Samba share.

## API

### `POST /logs/{device_name}`

Upload a log file for a device. The request body is the raw log content (text/plain).

```
POST http://nasbox.local:8765/logs/garage-sensor
Authorization: Bearer <token>
Content-Type: text/plain

2026-04-14 09:00:01 INFO  Sensor started
2026-04-14 09:00:05 INFO  Temperature: 21.3°C
```

The file is saved as `/mnt/logs/{device_name}/YYYY-MM-DD_HH-MM-SS.log` using the server's timestamp at the moment of receipt.

### `GET /health`

Returns `{"status": "ok"}`. Useful for checking the service is up.

## Deployment

Use the script at `logserver/scripts/deploy.sh`, or follow these steps manually.

### Dependencies

```bash
sudo apt install -y python3-pip
pip3 install fastapi uvicorn
```

### Configuration

The server reads one environment variable:

| Variable | Description | Example |
|---|---|---|
| `LOG_TOKEN` | Shared secret for Bearer auth | `change-me-to-something-long` |

Set it in the systemd service (see below) — do not commit it to this repo.

### Deploy the service

Copy `logserver/src/main.py` to the Pi:

```bash
scp logserver/src/main.py nakomis@nasbox.local:/home/nakomis/logserver.py
```

Create the systemd service:

```bash
sudo tee /etc/systemd/system/logserver.service << 'EOF'
[Unit]
Description=ESP32 log upload server
After=network.target mnt-logs.mount

[Service]
User=nakomis
ExecStart=/usr/bin/python3 -m uvicorn logserver:app --host 0.0.0.0 --port 8765
WorkingDirectory=/home/nakomis
Environment=LOG_TOKEN=change-me-to-something-long
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now logserver
```

> **Change the token.** Edit `/etc/systemd/system/logserver.service` and replace `change-me-to-something-long` with a random string before starting the service. Then `sudo systemctl daemon-reload && sudo systemctl restart logserver`.

### Verify

```bash
curl -s http://nasbox.local:8765/health
# {"status":"ok"}

curl -X POST http://nasbox.local:8765/logs/test-device \
     -H "Authorization: Bearer your-token" \
     -H "Content-Type: text/plain" \
     -d "test log entry"
# {"saved":"test-device/2026-04-14_09-00-00.log"}

ls /mnt/logs/test-device/
```

## Monitoring

```bash
journalctl -f -u logserver
```

## Notes

- The service binds on port `8765` to avoid clashing with anything else. Change in the systemd service if needed.
- Filenames use the server timestamp, not the device clock — device clocks on ESP32s can drift significantly without NTP.
- The `After=mnt-logs.mount` dependency prevents the service starting before the LVM volume is mounted.
