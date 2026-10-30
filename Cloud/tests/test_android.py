import json
import unittest
import uuid
import httpx
from zeus_cloud.android import AndroidGateway
import test_api


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def test_unconfigured_worker_is_explicit_and_does_not_make_a_request(self):
        gateway=AndroidGateway(url='',key='');self.addAsyncCleanup(gateway.close)
        self.assertFalse(gateway.configured)
        with self.assertRaises(ValueError):gateway.access('owner','conversation')
    async def test_credentials_are_scoped_and_redirects_are_not_followed(self):
        requests=[]
        async def handler(request):requests.append(request);return httpx.Response(302,headers={'Location':'https://other.test'})
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler),follow_redirects=False)
        gateway=AndroidGateway(url='https://worker.test',key='k'*40,client=client);self.addAsyncCleanup(gateway.close)
        access=gateway.access('owner','conversation')
        self.assertNotIn('k'*40,json.dumps(access));self.assertEqual(access['expires_in'],300)
        with self.assertRaises(ValueError):await gateway.tool('owner','conversation','android_ui',{'operation':'tree'},'op')
        self.assertEqual(len(requests),1)
        self.assertNotIn('k'*40,str(requests[0].headers))


class AndroidAPITests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = test_api.APITests.asyncSetUp
    async def test_android_access_does_not_start_or_download_an_environment(self):
        r=await self.client.get('/v1/android/capabilities');self.assertEqual(r.status_code,200)
        self.assertFalse(r.json()['configured']);self.assertFalse(r.json()['automatic_start'])
        r=await self.client.post(f'/v1/android/{self.conversation}/access',json={});self.assertEqual(r.status_code,400)
    async def test_android_tools_are_server_owned_and_never_wait_for_the_iphone(self):
        tool={'name':'android_ui','description':'inspect','parameters':{'type':'object','properties':{}}}
        run={'owner':self.owner,'id':str(uuid.uuid4()),'conversation':self.conversation}
        with self.assertRaises(ValueError):await self.app.state.engine.tool(run,{'name':'android_ui','arguments':{'operation':'tree'},'id':'call'},None,set())

    async def test_conversation_delete_waits_for_confirmed_android_deletion(self):
        await self.store.put(self.owner,'conversation',self.conversation,{'title':'keep until lab deleted'})
        gateway=self.app.state.engine.android
        gateway.url=gateway.public_url='https://worker.test';gateway.key='k'*40
        await gateway.client.aclose()
        gateway.client=httpx.AsyncClient(transport=httpx.MockTransport(lambda request:httpx.Response(503)))
        result=await self.client.delete('/v1/conversations/'+self.conversation)
        self.assertEqual(result.status_code,400,result.text)
        self.assertIsNotNone(await self.store.get(self.owner,'conversation',self.conversation))
