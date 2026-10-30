import datetime
import importlib.util
import pathlib
import sys
import types
import unittest
from unittest.mock import patch

sys.modules.setdefault("boto3", types.ModuleType("boto3"))
path = pathlib.Path(__file__).parent / "dns_reconcile" / "handler.py"
spec = importlib.util.spec_from_file_location("dns_reconcile", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeEcs:
    def list_tasks(self, **kwargs):
        return {"taskArns": ["old", "new"]}

    def describe_tasks(self, **kwargs):
        start = datetime.datetime.now(datetime.timezone.utc)
        return {"tasks": [
            {"taskArn": "old", "lastStatus": "RUNNING", "healthStatus": "HEALTHY", "startedAt": start},
            {"taskArn": "new", "lastStatus": "RUNNING", "healthStatus": "UNKNOWN", "startedAt": start + datetime.timedelta(seconds=1)},
        ]}


class ReconcileTests(unittest.TestCase):
    def test_does_not_publish_new_task_before_it_is_healthy(self):
        task = module.current_healthy_task(FakeEcs(), "count", "count")
        self.assertEqual(task["taskArn"], "old")

    def test_rejects_service_with_no_running_task(self):
        class EmptyEcs:
            def list_tasks(self, **kwargs):
                return {"taskArns": []}

        with self.assertRaisesRegex(RuntimeError, "no running task"):
            module.current_healthy_task(EmptyEcs(), "count", "count")

    def test_updates_only_the_named_record_when_task_ip_changes(self):
        class Ecs:
            def list_tasks(self, **kwargs):
                return {"taskArns": ["task"]}

            def describe_tasks(self, **kwargs):
                return {"tasks": [{
                    "lastStatus": "RUNNING", "healthStatus": "HEALTHY",
                    "startedAt": datetime.datetime.now(datetime.timezone.utc),
                    "attachments": [{"details": [{"name": "networkInterfaceId", "value": "eni-1"}]}],
                }]}

        class Ec2:
            def describe_network_interfaces(self, **kwargs):
                return {"NetworkInterfaces": [{"Association": {"PublicIp": "203.0.113.7"}}]}

        class Secrets:
            def get_secret_value(self, **kwargs):
                return {"SecretString": "test-token"}

        clients = {"ecs": Ecs(), "ec2": Ec2(), "secretsmanager": Secrets()}
        environment = {
            "CLUSTER_NAME": "count", "SERVICE_NAME": "count", "CLOUDFLARE_ZONE_ID": "zone",
            "CLOUDFLARE_HOSTNAME": "count.trendpointlabs.com", "CLOUDFLARE_TOKEN_SECRET_ARN": "secret",
        }
        calls = []

        def fake_cloudflare(method, path, token, body=None):
            calls.append((method, path, body))
            if method == "GET":
                return [{"id": "record", "name": "count.trendpointlabs.com", "content": "203.0.113.8"}]
            return {}

        with patch.dict(module.os.environ, environment), \
             patch.object(module.boto3, "client", side_effect=clients.__getitem__, create=True), \
             patch.object(module, "cloudflare", side_effect=fake_cloudflare):
            self.assertEqual(module.handler({}, None), {"changed": True})
        self.assertEqual(calls[-1], ("PATCH", "/zones/zone/dns_records/record", {"content": "203.0.113.7"}))


if __name__ == "__main__":
    unittest.main()
