"""ssm.sh against a fake Parameter Store: the real AWS CLI, a local endpoint, dummy credentials.

Nothing here reaches AWS. The fake speaks just enough of the JSON protocol for the calls ssm.sh
makes, records every request, and can be told to deny a target.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

HELPER = Path(__file__).parents[1] / "ssm.sh"


class FakeParameterStore:
    def __init__(self):
        self.params, self.requests, self.deny = {}, [], set()
        self.empty_first_page = False  # the API may answer a page with no parameters and a NextToken

    def handle(self, target, body):
        self.requests.append((target, body))
        if target in self.deny:
            return 400, {"__type": "AccessDeniedException", "message": "denied by the test"}
        return getattr(self, target)(body)

    def _matches(self, filters, name):
        for f in filters:
            if f["Key"] == "Name" and name not in f["Values"]:
                return False
            if f["Key"] == "Path" and not name.startswith(f["Values"][0].rstrip("/") + "/"):
                return False
        return True

    def PutParameter(self, b):
        old = self.params.get(b["Name"])
        if old and not b.get("Overwrite"):
            return 400, {"__type": "ParameterAlreadyExists", "message": "exists"}
        if b.get("Overwrite") and b.get("Tags"):
            return 400, {"__type": "ValidationException", "message": "tags and overwrite"}
        version = old["Version"] + 1 if old else 1
        tags = old["Tags"] if old else b.get("Tags", [])
        versions = (old["versions"] if old else []) + [
            {"Version": version, "Value": b["Value"], "Description": b.get("Description", "")}]
        self.params[b["Name"]] = {**b, "Version": version, "Tags": tags, "versions": versions}
        return 200, {"Version": version, "Tier": b.get("Tier", "Standard")}

    def DescribeParameters(self, b):
        if self.empty_first_page and "NextToken" not in b:
            return 200, {"Parameters": [], "NextToken": "second-page"}
        rows = [{"Name": n, "Type": p["Type"], "Version": p["Version"], "Tier": p["Tier"], "KeyId": p["KeyId"],
                 "Description": p.get("Description", ""), "LastModifiedDate": 0}
                for n, p in sorted(self.params.items()) if self._matches(b.get("ParameterFilters", []), n)]
        return 200, {"Parameters": rows}

    def ListTagsForResource(self, b):
        return 200, {"TagList": self.params[b["ResourceId"]]["Tags"]}

    def AddTagsToResource(self, b):
        tags = [t for t in self.params[b["ResourceId"]]["Tags"] if t["Key"] not in {n["Key"] for n in b["Tags"]}]
        self.params[b["ResourceId"]]["Tags"] = tags + b["Tags"]
        return 200, {}

    def LabelParameterVersion(self, b):
        target = b.get("ParameterVersion") or self.params[b["Name"]]["Version"]
        labels = b["Labels"]
        for v in self.params[b["Name"]]["versions"]:
            v["Labels"] = [l for l in v.get("Labels", []) if l not in labels]  # one version at a time
            if v["Version"] == target:
                v["Labels"] += labels
        return 200, {"InvalidLabels": [], "ParameterVersion": target}

    def GetParameterHistory(self, b):
        return 200, {"Parameters": [{"Name": b["Name"], "Type": "SecureString", "LastModifiedDate": 0, "Labels": [], **v}
                                    for v in self.params[b["Name"]]["versions"]]}

    def GetParameter(self, b):
        p = self.params[b["Name"]]
        return 200, {"Parameter": {"Name": b["Name"], "Type": p["Type"], "Value": p["Value"],
                                   "Version": p["Version"], "DataType": "text"}}


class SsmHelperTests(unittest.TestCase):
    def setUp(self):
        self.store = FakeParameterStore()
        store = self.store

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                target = self.headers["X-Amz-Target"].split(".")[-1]
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
                status, reply = store.handle(target, body)
                data = json.dumps(reply).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/x-amz-json-1.1")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.state = tempfile.TemporaryDirectory()
        # resolved: macOS temp paths run through /var -> /private/var, and custody refuses a symlink
        state_dir = Path(self.state.name).resolve()
        aws = state_dir / "aws"
        aws.mkdir(mode=0o700)
        (aws / "access_key_id").write_text("AKIDFAKE")
        (aws / "secret_access_key").write_text("fake-secret")
        (aws / "config.json").write_text('{"region": "us-west-1"}')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
        self.env.update(SECRET_STATE_DIR=str(state_dir), AWS_CONFIG_FILE="/dev/null",
                        AWS_SHARED_CREDENTIALS_FILE="/dev/null", AWS_MAX_ATTEMPTS="1",
                        AWS_EC2_METADATA_DISABLED="true",
                        AWS_ENDPOINT_URL=f"http://127.0.0.1:{self.server.server_address[1]}")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.state.cleanup()

    def run_helper(self, *args, value=None):
        return subprocess.run(["bash", str(HELPER), *args], input=value, env=self.env,
                              capture_output=True, text=True, timeout=60)

    def put(self, name, value, *flags):
        return self.run_helper("put", name, "--description", "a test value", *flags, value=value)

    def refused(self, result, reason):
        # A refusal counts only for the reason expected; a broken fixture fails too, for another one.
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(reason, result.stderr)

    def test_layout(self):
        for name in ["/devops/staging-cluster-a/billing/kek",
                     "/devops/dev-cluster/shop/checkout-service/db",
                     "/devops/dev-cluster/monitoring/grafana/auth/oauth/client_secret",
                     "/devops/c/ns/" + "s/" * 11 + "leaf"]:
            self.assertEqual(self.run_helper("check", name).returncode, 0, name)
        for name, reason in [("/devops/dev-cluster/trellis", "at least"),
                             ("/devops/Dev/trellis/kek", "'Dev' must be"),
                             ("/devops/dev-cluster/trellis/service-token", "must be snake_case"),
                             ("/devops/dev-cluster/trellis_ns/kek", "'trellis_ns' must be"),
                             ("/devops/dev-cluster//kek", "'' must be"),
                             ("/devops/-c/trellis/kek", "'-c' must be"),
                             ("/lab-cluster00/trellis/kek", "outside /devops/"),
                             ("/devops/c/ns/" + "s/" * 12 + "leaf", "15 levels"),
                             ("/dev-generic/wildcard_tls_key", "belongs to another team")]:
            with self.subTest(name=name):
                self.refused(self.run_helper("check", name), reason)
        self.assertEqual(self.run_helper("check", "/dev-generic/wildcard_tls_key", "--foreign").returncode, 0)
        self.refused(self.run_helper("check", "/dev-generic/a/b", "--foreign"), "that realm is flat")

    def test_create_is_advanced_securestring_under_the_key_and_strips_one_newline(self):
        r = self.put("/devops/dev-cluster/trellis/kek", "k3y\n\n", "--key-class")
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.store.params["/devops/dev-cluster/trellis/kek"]
        self.assertEqual((p["Type"], p["Tier"], p["KeyId"]), ("SecureString", "Advanced", "alias/eso-groundwork"))
        self.assertEqual(p["Value"], "k3y\n")
        self.assertEqual(sorted((t["Key"], t["Value"]) for t in p["Tags"]),
                         [("class", "key"), ("managed-by", "ssm.sh")])
        self.assertNotIn("k3y", r.stdout + r.stderr)

    def test_exact_keeps_the_bytes(self):
        self.assertEqual(self.put("/devops/c/ns/pem", "line\n", "--exact").returncode, 0)
        self.assertEqual(self.store.params["/devops/c/ns/pem"]["Value"], "line\n")

    def test_refuses_empty_values_missing_descriptions_and_existing_names(self):
        self.refused(self.put("/devops/c/ns/a", "\n"), "is empty")
        self.refused(self.run_helper("put", "/devops/c/ns/a", value="v"), "--description is required")
        self.assertEqual(self.put("/devops/c/ns/a", "v1").returncode, 0)
        self.refused(self.put("/devops/c/ns/a", "v2"), "exists; --overwrite")
        r = self.put("/devops/c/ns/a", "v2", "--overwrite")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.store.params["/devops/c/ns/a"]["Version"], 2)
        overwrite = [b for t, b in self.store.requests if t == "PutParameter"][-1]
        self.assertTrue(overwrite["Overwrite"])
        self.assertNotIn("Tags", overwrite)

    def test_a_key_needs_new_key_version_to_overwrite(self):
        self.assertEqual(self.put("/devops/c/ns/kek", "one", "--key-class").returncode, 0)
        self.refused(self.put("/devops/c/ns/kek", "two", "--overwrite"), "is a key")
        self.assertEqual(self.store.params["/devops/c/ns/kek"]["Value"], "one")
        self.assertEqual(self.put("/devops/c/ns/kek", "two", "--overwrite", "--new-key-version").returncode, 0)
        self.assertEqual(self.store.params["/devops/c/ns/kek"]["Version"], 2)

    def test_a_node_is_a_parameter_or_a_folder(self):
        self.assertEqual(self.put("/devops/c/ns/app/db", '{"username":"u","password":"p"}').returncode, 0)
        self.refused(self.put("/devops/c/ns/app/db/password", "p"), "parent folders is already a parameter")
        self.assertEqual(self.put("/devops/c/ns/other/db/password", "p").returncode, 0)
        self.refused(self.put("/devops/c/ns/other/db", "x"), "parameters exist below it")

    def test_an_aws_error_is_a_failure_not_an_answer(self):
        self.assertEqual(self.put("/devops/c/ns/kek", "one", "--key-class").returncode, 0)
        self.store.deny.add("ListTagsForResource")
        r = self.put("/devops/c/ns/kek", "two", "--overwrite", "--new-key-version")
        self.refused(r, "AccessDeniedException")
        self.assertEqual(self.store.params["/devops/c/ns/kek"]["Value"], "one")
        r = self.put("/devops/c/ns/kek", "two", "--overwrite")
        self.refused(r, "AccessDeniedException")
        self.assertNotIn("is a key", r.stderr)
        self.store.deny = {"DescribeParameters"}
        self.refused(self.put("/devops/c/ns/fresh", "v"), "AccessDeniedException")
        self.assertNotIn("/devops/c/ns/fresh", self.store.params)

    def test_cli_history_on_refuses_before_any_call(self):
        config = Path(self.state.name).resolve() / "aws-config"
        config.write_text("[default]\ncli_history = enabled\n")
        self.env["AWS_CONFIG_FILE"] = str(config)
        self.refused(self.put("/devops/c/ns/a", "v"), "cli_history is enabled")
        self.refused(self.run_helper("copy-tree", "/devops/c/ns", "/devops/d/ns"), "cli_history is enabled")
        self.assertEqual(self.store.requests, [])

    def test_names_with_a_trailing_slash_or_a_newline_are_refused(self):
        self.refused(self.run_helper("check", "/devops/c/ns/a/"), "trailing slash")
        self.refused(self.run_helper("check", "/devops/c/ns/a\n/devops/c/ns/b"), "one line")

    def test_an_empty_first_page_is_not_an_answer(self):
        self.store.empty_first_page = True
        self.assertEqual(self.put("/devops/c/ns/a", "v1").returncode, 0)
        self.refused(self.put("/devops/c/ns/a", "v2"), "exists; --overwrite")

    def test_overwrite_refuses_a_parameter_ssm_sh_did_not_write(self):
        self.store.params["/devops/c/ns/other"] = {
            "Name": "/devops/c/ns/other", "Type": "String", "Tier": "Standard", "KeyId": "", "Value": "x", "Version": 1,
            "Tags": [{"Key": "managed-by", "Value": "external-secrets"}], "versions": [{"Version": 1, "Value": "x"}]}
        self.refused(self.put("/devops/c/ns/other", "y", "--overwrite"), "not written by ssm.sh")
        self.assertEqual(self.store.params["/devops/c/ns/other"]["Version"], 1)

    def test_key_class_asked_for_on_an_overwrite_is_applied(self):
        self.assertEqual(self.put("/devops/c/ns/kek", "one").returncode, 0)
        self.refused(self.put("/devops/c/ns/kek", "two", "--overwrite", "--key-class"), "is a key")
        self.assertEqual(self.put("/devops/c/ns/kek", "two", "--overwrite", "--key-class", "--new-key-version").returncode, 0)
        self.assertIn({"Key": "class", "Value": "key"}, self.store.params["/devops/c/ns/kek"]["Tags"])
        self.refused(self.put("/devops/c/ns/kek", "three", "--overwrite"), "is a key")

    def test_foreign_realm_needs_the_flag(self):
        self.refused(self.put("/dev-generic/wildcard_tls_key", "k"), "belongs to another team")
        self.assertEqual(self.put("/dev-generic/wildcard_tls_key", "k", "--foreign").returncode, 0)

    def test_copy_tree_replays_every_version_so_pins_name_the_same_bytes(self):
        self.assertEqual(self.put("/devops/old/app/kek", "s3cr3t-v1", "--key-class").returncode, 0)
        self.assertEqual(self.put("/devops/old/app/kek", "s3cr3t-v2", "--overwrite", "--new-key-version").returncode, 0)
        r = self.run_helper("copy-tree", "/devops/old/app", "/devops/new/app")
        self.assertEqual(r.returncode, 0, r.stderr)
        copied = self.store.params["/devops/new/app/kek"]
        self.assertEqual([(v["Version"], v["Value"]) for v in copied["versions"]], [(1, "s3cr3t-v1"), (2, "s3cr3t-v2")])
        self.assertIn({"Key": "class", "Value": "key"}, copied["Tags"])
        self.assertNotIn("s3cr3t", r.stdout + r.stderr)

    def test_copy_tree_refuses_a_history_it_cannot_replay_with_the_same_numbers(self):
        self.assertEqual(self.put("/devops/old/app/kek", "v1", "--key-class").returncode, 0)
        self.assertEqual(self.put("/devops/old/app/kek", "v2", "--overwrite", "--new-key-version").returncode, 0)
        self.store.params["/devops/old/app/kek"]["versions"].pop(0)  # version 1 aged out
        self.refused(self.run_helper("copy-tree", "/devops/old/app", "/devops/new/app"), "are not 1..1")
        self.assertNotIn("/devops/new/app/kek", self.store.params)

    def test_copy_tree_needs_a_namespace_on_both_sides(self):
        self.refused(self.run_helper("copy-tree", "/devops", "/devops/x/y"), "outside /devops/")
        self.refused(self.run_helper("copy-tree", "/devops/old", "/devops/new/app"), "copy-tree works on")
        self.refused(self.run_helper("copy-tree", "/devops/old/app", "/devops/old/app"), "the same")

    def test_copy_tree_keeps_values_descriptions_and_key_class(self):
        self.assertEqual(self.put("/devops/old/trellis/kek", "s3cr3t-kek\n", "--key-class", "--exact").returncode, 0)
        self.assertEqual(self.put("/devops/old/trellis/nested/token", "t").returncode, 0)
        r = self.run_helper("copy-tree", "/devops/old/trellis", "/devops/new/trellis")
        self.assertEqual(r.returncode, 0, r.stderr)
        kek = self.store.params["/devops/new/trellis/kek"]
        self.assertEqual((kek["Value"], kek["Description"]), ("s3cr3t-kek\n", "a test value"))
        self.assertIn({"Key": "class", "Value": "key"}, kek["Tags"])
        self.assertEqual(self.store.params["/devops/new/trellis/nested/token"]["Value"], "t")
        self.assertNotIn("s3cr3t", r.stdout + r.stderr)
        self.refused(self.run_helper("copy-tree", "/devops/old/trellis", "/devops/new/trellis"), "already holds parameters")
        self.refused(self.run_helper("copy-tree", "/devops/old/trelis", "/devops/newer/trellis"), "holds no parameters")

    def test_copy_tree_replays_labels_onto_the_same_version_numbers(self):
        self.assertEqual(self.put("/devops/old/app/kek", "s3cr3t-v1", "--key-class").returncode, 0)
        self.assertEqual(self.put("/devops/old/app/kek", "s3cr3t-v2", "--overwrite", "--new-key-version").returncode, 0)
        self.store.params["/devops/old/app/kek"]["versions"][0]["Labels"] = ["previous"]
        self.store.params["/devops/old/app/kek"]["versions"][1]["Labels"] = ["pinned"]
        r = self.run_helper("copy-tree", "/devops/old/app", "/devops/new/app")
        self.assertEqual(r.returncode, 0, r.stderr)
        versions = self.store.params["/devops/new/app/kek"]["versions"]
        self.assertEqual(versions[0]["Labels"], ["previous"])
        self.assertEqual(versions[1]["Labels"], ["pinned"])
        self.assertNotIn("s3cr3t", r.stdout + r.stderr)

    def test_copy_tree_stops_loudly_when_labelling_the_copy_fails(self):
        self.assertEqual(self.put("/devops/old/app/a", "v1").returncode, 0)
        self.store.params["/devops/old/app/a"]["versions"][0]["Labels"] = ["pinned"]
        self.store.deny.add("LabelParameterVersion")
        self.refused(self.run_helper("copy-tree", "/devops/old/app", "/devops/new/app"), "AccessDeniedException")

    def test_copy_tree_refuses_before_writing_anything_when_a_later_parameter_has_a_gap(self):
        self.assertEqual(self.put("/devops/old/app/a", "v1").returncode, 0)
        self.assertEqual(self.put("/devops/old/app/z", "v1").returncode, 0)
        self.assertEqual(self.put("/devops/old/app/z", "v2", "--overwrite").returncode, 0)
        self.store.params["/devops/old/app/z"]["versions"].pop(0)  # version 1 aged out; z's history now starts at 2
        r = self.run_helper("copy-tree", "/devops/old/app", "/devops/new/app")
        self.refused(r, "are not 1..1")
        self.assertNotIn("/devops/new/app/a", self.store.params)
        self.assertNotIn("/devops/new/app/z", self.store.params)
        # No decrypted read happened either: pass two, which would have copied "a", never started.
        self.assertTrue(all("WithDecryption" not in b for t, b in self.store.requests if t == "GetParameterHistory"))


if __name__ == "__main__":
    unittest.main()
