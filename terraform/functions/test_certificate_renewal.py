import importlib.util
import json
import pathlib
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

sys.modules.setdefault("boto3", types.ModuleType("boto3"))
path = pathlib.Path(__file__).parent / "certificate_renewal" / "handler.py"
spec = importlib.util.spec_from_file_location("certificate_renewal", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CertificateRenewalTests(unittest.TestCase):
    def test_expiry_check_alarms_before_certificate_expires(self):
        class Acm:
            def describe_certificate(self, **kwargs):
                return {"Certificate": {"Status": "ISSUED", "NotAfter": datetime.now(timezone.utc) + timedelta(days=20)}}

        with patch.dict(module.os.environ, {"CERTIFICATE_ARN": "expected"}), \
             patch.object(module.boto3, "client", return_value=Acm(), create=True):
            with self.assertRaisesRegex(RuntimeError, "less than 30 days"):
                module.handler({"check_expiry": True}, None)

    def test_ignores_unrelated_certificate_events(self):
        with patch.dict(module.os.environ, {"CERTIFICATE_ARN": "expected"}):
            event = {"detail": {"Action": "RENEWAL"}, "resources": ["another"]}
            self.assertEqual(module.handler(event, None), {"changed": False})

    def test_bootstrap_stores_certificate_without_redeploying_http_task(self):
        class Acm:
            def export_certificate(self, **kwargs):
                return {"Certificate": "CERT\n", "CertificateChain": "CHAIN\n", "PrivateKey": "KEY"}

        class Secrets:
            def __init__(self):
                self.saved = None

            def put_secret_value(self, **kwargs):
                self.saved = kwargs

        secrets = Secrets()
        clients = {"acm": Acm(), "secretsmanager": secrets}
        environment = {"CERTIFICATE_ARN": "expected", "TLS_BUNDLE_SECRET_ARN": "secret", "HTTPS_ENABLED": "false"}
        with patch.dict(module.os.environ, environment), patch.object(module.boto3, "client", side_effect=clients.__getitem__, create=True):
            self.assertEqual(module.handler({"bootstrap": True}, None), {"changed": True})
        self.assertEqual(secrets.saved["SecretId"], "secret")
        self.assertIn("CERT\nCHAIN", json.loads(secrets.saved["SecretString"])["certificate"])


if __name__ == "__main__":
    unittest.main()
