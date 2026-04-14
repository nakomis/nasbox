import os
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

LOG_DIR = Path(os.getenv("LOG_DIR", "/mnt/logs"))
LOG_TOKEN = os.getenv("LOG_TOKEN", "")

app = FastAPI(title="nasbox logserver")
bearer = HTTPBearer()


def _check_token(credentials: HTTPAuthorizationCredentials) -> None:
    if not LOG_TOKEN:
        raise RuntimeError("LOG_TOKEN environment variable is not set")
    if credentials.credentials != LOG_TOKEN:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/logs/{device_name}")
async def upload_log(device_name: str, request: Request, credentials: HTTPAuthorizationCredentials = bearer()) -> dict:
    _check_token(credentials)

    if not device_name.replace("-", "").replace("_", "").isalnum():
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid device name")

    body = await request.body()
    if not body:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Empty body")

    device_dir = LOG_DIR / device_name
    device_dir.mkdir(parents=True, exist_ok=True)

    filename = datetime.now().strftime("%Y-%m-%d_%H-%M-%S") + ".log"
    (device_dir / filename).write_bytes(body)

    return {"saved": f"{device_name}/{filename}"}
