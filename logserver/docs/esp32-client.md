# Log Server — ESP32 Client

How to upload log files from an ESP32 to the nasbox logserver.

## Overview

The ESP32 buffers log lines to a file on its flash (SPIFFS or LittleFS), then POSTs the file to the logserver when WiFi is available. If WiFi is unavailable, it continues buffering and flushes the backlog on reconnect.

## Arduino / ESP-IDF example

```cpp
#include <WiFi.h>
#include <HTTPClient.h>
#include <LittleFS.h>

const char* LOGSERVER_URL = "http://nasbox.local:8765/logs/my-device";
const char* LOG_TOKEN     = "change-me-to-something-long";
const char* LOG_FILE      = "/pending.log";

// Call this from your logging code to append a line
void writeLog(const char* line) {
    File f = LittleFS.open(LOG_FILE, "a");
    if (f) {
        f.println(line);
        f.close();
    }
}

// Call this periodically (e.g. every 10 minutes, or on reconnect)
bool flushLogs() {
    if (WiFi.status() != WL_CONNECTED) return false;

    File f = LittleFS.open(LOG_FILE, "r");
    if (!f || f.size() == 0) return true;   // nothing to send

    String body = f.readString();
    f.close();

    HTTPClient http;
    http.begin(LOGSERVER_URL);
    http.addHeader("Authorization", String("Bearer ") + LOG_TOKEN);
    http.addHeader("Content-Type", "text/plain");

    int code = http.POST(body);
    http.end();

    if (code == 200) {
        LittleFS.remove(LOG_FILE);  // only delete after confirmed upload
        return true;
    }
    return false;   // leave file intact; retry next time
}
```

> **Delete only on success.** The file is removed only after a confirmed HTTP 200 response. If the upload fails (network drop mid-transfer, server error), the file remains and the full backlog is retried next time.

## Backlog behaviour

If the device goes offline for an extended period, `pending.log` grows unboundedly (limited only by available flash). For devices with long offline windows, consider:

- Rotating to a new file when `pending.log` exceeds a size threshold (e.g. 100KB)
- Keeping only the N most recent files
- Dropping the oldest lines when flash is nearly full

## Device naming

The device name in the URL path (`my-device` above) determines which subdirectory the log lands in on the nasbox. Use a consistent, descriptive name — e.g. `garage-sensor`, `workshop-env`, `front-door`. Avoid spaces and special characters.

## Flush triggers

Reasonable triggers for calling `flushLogs()`:

- On WiFi reconnect (most important — clears backlogs promptly)
- Every N minutes via a timer
- When `pending.log` exceeds a size threshold
- On clean shutdown / deep sleep entry

## Token management

The Bearer token is a shared secret between the ESP32 firmware and the logserver. Store it in a header file excluded from version control, or use NVS to store it separately from the main firmware image.
