import json
from pathlib import Path
import tempfile
import unittest
import httpx
from zeus_cloud.providers import Models, with_tool_images
from zeus_cloud.patches import apply_patch


class Contracts(unittest.IsolatedAsyncioTestCase):
    async def test_responses_stream_preserves_actual_tool_id_and_schema(self):
        captured = []
        events = [
            {"type":"response.output_text.delta","delta":"Checking "},
            {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_native","name":"file_edit","arguments":""}},
            {"type":"response.function_call_arguments.delta","output_index":0,"delta":'{"path":"test.txt"}'},
            {"type":"response.completed"},
        ]
        async def transport(request):
            captured.append(json.loads(request.content))
            return httpx.Response(200, text="\n".join("data: "+json.dumps(e) for e in events))
        client = httpx.AsyncClient(transport=httpx.MockTransport(transport)); self.addAsyncCleanup(client.aclose)
        tools = [{"name":"file_edit","description":"original","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}]
        provider = {"kind":"responses","base_url":"https://provider.test/v1","model":"selected-model","api_key":"fixture-only"}
        result = [event async for event in Models(client).stream(provider, [{"role":"user","content":"edit"}], tools, "original prompt")]
        self.assertEqual(result[-1], {"kind":"tool","id":"call_native","name":"file_edit","arguments":{"path":"test.txt"}})
        self.assertEqual(captured[0]["tools"][0]["parameters"], tools[0]["parameters"])
        self.assertFalse(captured[0]["store"])
        self.assertEqual(captured[0]["model"], "selected-model")

    def test_device_images_follow_complete_tool_batch_and_keep_actual_pixels(self):
        image={"mime":"image/png","data":"YWJj"}
        messages=[{"role":"tool","tool_call_id":"a","content":"screenshot","image":image}, {"role":"tool","tool_call_id":"b","content":"page text"}]
        result=with_tool_images(messages)
        self.assertEqual([m["role"] for m in result], ["tool","tool","user"])
        self.assertEqual(result[-1]["content"][-1]["image_url"]["url"], "data:image/png;base64,YWJj")
        self.assertNotIn("image",result[0])
        self.assertIn("image",messages[0])

    def test_patch_preflights_all_files_before_mutating_and_rejects_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/"one.txt").write_text("old\n")
            patch="*** Begin Patch\n*** Update File: one.txt\n@@\n-old\n+new\n*** Update File: absent.txt\n@@\n-x\n+y\n*** End Patch"
            with self.assertRaises(FileNotFoundError): apply_patch(root,patch)
            self.assertEqual((root/"one.txt").read_text(),"old\n")
            with self.assertRaises(ValueError): apply_patch(root,"*** Begin Patch\n*** Add File: ../escape\n+x\n*** End Patch")
            result=apply_patch(root,"*** Begin Patch\n*** Update File: one.txt\n@@\n-old\n+new\n*** Add File: nested/two.txt\n+created\n*** End Patch")
            self.assertEqual((root/"one.txt").read_text(),"new\n")
            self.assertEqual((root/"nested/two.txt").read_text(),"created\n")
