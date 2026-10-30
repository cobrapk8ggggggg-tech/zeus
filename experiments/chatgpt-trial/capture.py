"""Passive, bounded observation of the test guest; never bypasses app TLS checks."""
import json
import os
import time
from zeus_android.capture import Capture

class Recorder(Capture):
    def __init__(self):super().__init__();self.count=0;self.size=0
    def emit(self,event):
        event={'timestamp':time.time(),**event};raw=(json.dumps(event,ensure_ascii=False)+'\n').encode()
        if self.count>=1500 or self.size+len(raw)>8*1024*1024:return
        self.count+=1;self.size+=len(raw)
        with open(os.environ['CHATGPT_CAPTURE_FILE'],'ab') as output:output.write(raw)
    def http_connect(self,flow):
        self.emit({'phase':'connect','method':'CONNECT','url':flow.request.pretty_url,'flow_id':flow.id})
    def tls_failed_client(self,data):
        self.emit({'phase':'tls_failed_client','sni':data.context.client.sni,'error':str(data.context.client.error)[:600]})
    def tls_failed_server(self,data):
        self.emit({'phase':'tls_failed_server','sni':data.context.client.sni,'error':str(data.context.server.error)[:600]})

addons=[Recorder()]
