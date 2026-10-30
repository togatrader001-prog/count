import base64
import json
import os
from datetime import datetime, timezone

import boto3


def handler(event, context):
    if event.get("check_expiry"):
        certificate = boto3.client("acm").describe_certificate(
            CertificateArn=os.environ["CERTIFICATE_ARN"]
        )["Certificate"]
        if certificate["Status"] == "PENDING_VALIDATION":
            return {"status": certificate["Status"]}
        if certificate["Status"] != "ISSUED":
            raise RuntimeError("Count TLS certificate is not issued")
        remaining = certificate["NotAfter"] - datetime.now(timezone.utc)
        if remaining.days < 30:
            raise RuntimeError("Count TLS certificate expires in less than 30 days")
        return {"days_remaining": remaining.days}
    if not event.get("bootstrap") and event.get("detail", {}).get("Action") != "RENEWAL":
        return {"changed": False}
    if event.get("resources") and os.environ["CERTIFICATE_ARN"] not in event["resources"]:
        return {"changed": False}

    passphrase = base64.urlsafe_b64encode(os.urandom(48))
    certificate = boto3.client("acm").export_certificate(
        CertificateArn=os.environ["CERTIFICATE_ARN"], Passphrase=passphrase
    )
    bundle = {
        "certificate": certificate["Certificate"].rstrip() + "\n" + certificate["CertificateChain"],
        "privateKey": certificate["PrivateKey"],
        "passphrase": passphrase.decode(),
    }
    secrets = boto3.client("secretsmanager")
    if not event.get("bootstrap"):
        existing = json.loads(secrets.get_secret_value(
            SecretId=os.environ["TLS_BUNDLE_SECRET_ARN"]
        )["SecretString"])
        if existing["certificate"] == bundle["certificate"]:
            return {"changed": False}
    secrets.put_secret_value(
        SecretId=os.environ["TLS_BUNDLE_SECRET_ARN"], SecretString=json.dumps(bundle)
    )
    if os.environ.get("HTTPS_ENABLED") == "true":
        boto3.client("ecs").update_service(
            cluster=os.environ["CLUSTER_NAME"], service=os.environ["SERVICE_NAME"], forceNewDeployment=True
        )
    return {"changed": True}
