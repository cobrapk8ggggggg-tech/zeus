import os
import uvicorn

uvicorn.run("agent_service.app:create_app", factory=True, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), access_log=False, workers=1)
