"""UI inspection only: no simulated Android device and no production credentials."""
import os
import tempfile
import uvicorn
from zeus_android.app import create_app

if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        app=create_app(root=directory,key=os.environ['LAB_TEST_KEY'],owner='ui-test')
        uvicorn.run(app,host='127.0.0.1',port=8769,access_log=False,log_level='warning')
