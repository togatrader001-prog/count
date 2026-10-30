import json
import os
import urllib.error
import urllib.request
import urllib.parse

import boto3


def cloudflare(method, path, token, body=None):
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Cloudflare DNS request failed: HTTP {error.code}") from None
    if not result.get("success"):
        raise RuntimeError("Cloudflare DNS request failed")
    return result["result"]


def current_healthy_task(ecs, cluster, service):
    task_arns = ecs.list_tasks(cluster=cluster, serviceName=service, desiredStatus="RUNNING")["taskArns"]
    if not task_arns:
        raise RuntimeError("Count service has no running task")
    tasks = ecs.describe_tasks(cluster=cluster, tasks=task_arns)["tasks"]
    healthy = [task for task in tasks if task["lastStatus"] == "RUNNING" and task.get("healthStatus") == "HEALTHY"]
    if not healthy:
        raise RuntimeError("Count service has no healthy running task")
    return max(healthy, key=lambda task: task["startedAt"])


def handler(event, context):
    ecs = boto3.client("ecs")
    ec2 = boto3.client("ec2")
    secrets = boto3.client("secretsmanager")
    task = current_healthy_task(ecs, os.environ["CLUSTER_NAME"], os.environ["SERVICE_NAME"])
    eni_id = next(detail["value"] for attachment in task["attachments"]
                  for detail in attachment["details"] if detail["name"] == "networkInterfaceId")
    eni = ec2.describe_network_interfaces(NetworkInterfaceIds=[eni_id])["NetworkInterfaces"][0]
    public_ip = eni["Association"]["PublicIp"]

    token = secrets.get_secret_value(SecretId=os.environ["CLOUDFLARE_TOKEN_SECRET_ARN"])["SecretString"]
    zone_path = f'/zones/{os.environ["CLOUDFLARE_ZONE_ID"]}/dns_records'
    query = urllib.parse.urlencode({"type": "A", "name": os.environ["CLOUDFLARE_HOSTNAME"]})
    records = cloudflare("GET", f"{zone_path}?{query}", token)
    if len(records) != 1 or records[0]["name"] != os.environ["CLOUDFLARE_HOSTNAME"]:
        raise RuntimeError("Expected exactly one Count A record in Cloudflare")
    record = records[0]
    if record["content"] == public_ip:
        return {"changed": False}
    cloudflare("PATCH", f'{zone_path}/{record["id"]}', token, {"content": public_ip})
    return {"changed": True}
