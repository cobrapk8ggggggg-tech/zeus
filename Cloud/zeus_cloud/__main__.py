import os
import uvicorn
from .app import create_app

uvicorn.run(create_app(), host="0.0.0.0", port=int(os.environ.get("PORT", "8080")),
            log_level="warning", access_log=False, limit_concurrency=8, timeout_keep_alive=5)
