import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("custody", Path(__file__).parents[1] / "custody.py")
custody = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(custody)


class CustodyTests(unittest.TestCase):
    def test_atomic_write_is_private_even_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as d:
            old = os.umask(0)
            try:
                p = Path(d).resolve() / "private" / "state.json"
                custody.write_private(p, '{"test":1}')
                self.assertEqual(p.stat().st_mode & 0o777, 0o600)
                self.assertEqual(p.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(json.loads(p.read_text()), {"test": 1})
            finally:
                os.umask(old)

    def test_refuses_symlink_destination_and_parent(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve()
            target = root / "target"
            target.write_text("untouched")
            (root / "link").symlink_to(target)
            with self.assertRaises(ValueError):
                custody.write_private(root / "link", "bad")
            (root / "dirlink").symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                custody.write_private(root / "dirlink" / "file", "bad")
            self.assertEqual(target.read_text(), "untouched")

    def test_key_merge_retains_old_keys_and_removes_cluster_metadata(self):
        def key(name, value):
            return {"apiVersion": "v1", "kind": "Secret", "metadata": {
                "name": name, "namespace": "sealed-secrets", "uid": "cluster-specific",
                "resourceVersion": "42", "annotations": {"unsafe": "secret"}},
                "type": "kubernetes.io/tls", "data": {"tls.key": value, "tls.crt": value}}
        merged = custody.merge_keys([key("old", "a")], [key("new", "b")])
        self.assertEqual([x["metadata"]["name"] for x in merged], ["old", "new"])
        self.assertNotIn("uid", merged[0]["metadata"])
        self.assertNotIn("annotations", merged[0]["metadata"])
        self.assertEqual(merged[0]["metadata"]["labels"], {
            "sealedsecrets.bitnami.com/sealed-secrets-key": "active"})

    def test_changed_key_with_same_name_is_rejected_instead_of_destroying_history(self):
        a = {"metadata": {"name": "same"}, "data": {"tls.key": "a", "tls.crt": "a"}}
        b = {"metadata": {"name": "same"}, "data": {"tls.key": "b", "tls.crt": "b"}}
        with self.assertRaises(ValueError):
            custody.merge_keys([a], [b])

    def test_invalid_key_is_rejected_before_backup_replacement(self):
        with self.assertRaises(ValueError):
            custody.merge_keys([], [{"metadata": {"name": "bad"}, "data": {}}])


if __name__ == "__main__":
    unittest.main()
