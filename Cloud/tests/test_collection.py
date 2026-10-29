import json
import unittest
from zeus_cloud.collection import Collection, references


class CollectionTests(unittest.IsolatedAsyncioTestCase):
    def test_plaintext_checksum_is_not_mistaken_for_an_encrypted_storage_reference(self):
        raw, encrypted = "a"*64, "b"*64
        self.assertEqual(references({"files":[{"sha256":raw,"bytes":10,"parts":[{"sha256":encrypted,"bytes":38}]}]}), {encrypted})

    async def test_shared_file_and_current_archive_survive_collection_of_deleted_chat(self):
        current, old, shared, removed = [c*64 for c in "abcd"]
        def ref(value): return {"sha256":value,"bytes":100}
        class Store:
            deleted=[]
            async def gc_snapshot(self, owner): return {"revision":7,"deletion_epoch":1,"native":ref(current),"native_refs":[ref(current),ref(old)]}
            async def gc_prepare(self, owner, revision, epoch, candidates, prune):
                assert (revision,epoch,prune)==(7,1,True)
                assert removed in candidates
                return {"revision":7,"native_refs":[ref(current)],"roots":[ref(shared)],"candidates":[ref(old),ref(removed),ref(shared),ref(current)]}
            async def gc_delete(self, owner, revision, digest): self.deleted.append(digest);return {"deleted":True}
        class Gateway:
            async def get(self, token, r):
                data={"version":1,"deletionEpoch":1,"files":[{"scope":"agent_sessions","parts":[ref(shared)]}]}
                if r["sha256"]==old: data["files"].append({"scope":"native_database","parts":[ref(removed)]})
                return json.dumps(data).encode()
        store=Store();result=await Collection(store,Gateway()).collect("owner","token")
        self.assertEqual(result["deleted_objects"],2)
        self.assertEqual(set(store.deleted),{old,removed})

    async def test_missing_clean_replacement_retains_old_archives(self):
        current, old = "a"*64,"b"*64
        def ref(value): return {"sha256":value,"bytes":100}
        class Store:
            async def gc_snapshot(self, owner): return {"revision":1,"deletion_epoch":2,"native":ref(current),"native_refs":[ref(current),ref(old)]}
            async def gc_prepare(self, owner, revision, epoch, candidates, prune):
                assert not prune and candidates==[]
                return {"revision":1,"native_refs":[ref(current),ref(old)],"roots":[],"candidates":[ref(old)]}
            async def gc_delete(self,*args): raise AssertionError("Referenced backup must not be deleted")
        class Gateway:
            async def get(self,*args): return b'{"version":1,"files":[]}'
        self.assertEqual((await Collection(Store(),Gateway()).collect("owner","token"))["deleted_objects"],0)
