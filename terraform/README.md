# Direct Count domain rollout

Target: `https://count.trendpointlabs.com/count` -> Cloudflare A record -> one ECS Fargate task with a public IPv4 address. There is no load balancer, CloudFront distribution, or Route 53 zone.

## Review gate

The default `enable_https = false` preserves the existing port 3000 task access. Do not apply until the Terraform plan has been compared with the current state. Keep `terraform.tfstate`, plan files, token values, TLS bundles, and `terraform.tfvars` out of Git. This configuration currently uses local Terraform state; back it up securely before any apply. This configuration does not store secret *values* in Terraform state.

The `https_allowed_cidrs` variable defaults to empty, so the current `allowed_cidr` remains the only allowed source when HTTPS is first enabled. Public access requires a separate decision:

| Option | DNS | Security group | Protection |
| --- | --- | --- | --- |
| Private verification | DNS only | Gene's existing `/32` | Only that source can connect |
| Public direct | DNS only | `0.0.0.0/0` on 443 | App rate limiting or authentication must be added before opening |
| Public through Cloudflare (recommended for public access) | Proxied | Cloudflare's current origin IPv4 ranges on 443 | Full (strict) TLS, Free Managed Ruleset, and one Free-plan rate limiting rule; maintain the CIDR list |

The Free dashboard permits a 10-second counting period. The deployed rule blocks `GET /count` for 10 seconds when a source IP exceeds 10 requests in 10 seconds; it applies only to `count.trendpointlabs.com`. Confirm that Cloudflare caching does not serve repeated `/count` responses; the app sends `Cache-Control: no-store`. A Cloudflare Origin CA certificate alone would break DNS-only direct access, so this rollout uses a publicly trusted ACM exportable certificate.

## Preparation

1. In Cloudflare, create an API token with **DNS Write** limited to the `trendpointlabs.com` zone. Store its value directly in a new AWS Secrets Manager secret; never put it in Terraform variables, source files, command history, or chat. Record only the secret ARN. The token can edit records across this zone, so protect it accordingly.
2. Find the Cloudflare zone ID. Record that ID, which is not a credential.
3. Build and push the new Count image, retaining an immutable image tag. Keep the live service on its existing image until the HTTPS cutover.
4. Rebuild both Lambda ZIPs after any handler edit:

   ```powershell
   Compress-Archive -LiteralPath functions/dns_reconcile/handler.py -DestinationPath dns_reconcile.zip -Force
   Compress-Archive -LiteralPath functions/certificate_renewal/handler.py -DestinationPath certificate_renewal.zip -Force
   ```

## Staged rollout after review

1. Supply the existing `allowed_cidr` and `image_uri`, plus `cloudflare_zone_id` and `cloudflare_token_secret_arn`. Keep `enable_https = false`. Review a targeted plan for the ACM certificate, TLS secret, certificate renewal Lambda, and its task-execution permission before applying. Leave the DNS reconciler and its scheduled triggers disabled until a healthy HTTPS task exists; the previous HTTP task has no container health check.
2. Add the ACM validation CNAME shown by `terraform output acm_dns_validation` to Cloudflare as DNS only. Wait until the certificate status is `ISSUED` in ACM. Then invoke `count-certificate-renewal` once with `{ "bootstrap": true }`; it exports the certificate into the TLS bundle secret without restarting the current HTTP task.
3. Create a DNS-only Cloudflare A record named `count` with the current running task's public IPv4 address and TTL 60 seconds. Verify that exactly one such A record exists. The DNS Lambda looks it up by name and type; no record ID is needed as an input.
4. Set `enable_https = true` and `image_uri` to the new image tag. Temporarily include the operator's `/32` in `https_allowed_cidrs` for direct TLS verification and keep `keep_legacy_http = true` during the transition. Review and apply the ECS task, service, security group, and certificate Lambda changes. Wait until the new task is healthy, then verify `/health` and `/count` over HTTPS and confirm the certificate name and chain.
5. Review and apply the remaining DNS reconciler, EventBridge rules, and alarms. Invoke the DNS Lambda once to update the A record to the healthy task's address, then verify the result in Cloudflare. Set Full (strict), enable the Free Managed Ruleset and a `/count` rate limit, and change the A record to Proxied. Verify the public HTTPS route through Cloudflare. Then set `keep_legacy_http = false` and restrict `https_allowed_cidrs` to Cloudflare's published origin IPv4 ranges; review and apply that security group change. Verify direct-IP requests are blocked. Force one ECS replacement and confirm that the DNS Lambda follows the new healthy task address while the public route remains available. Recheck the CIDR list whenever Cloudflare updates its ranges.

The DNS function reconciles every minute and on ECS task-state events. It publishes only a running, healthy task, preferring the newest healthy task during deployment. With no healthy task it leaves DNS unchanged and raises a Lambda error. DNS propagation and a single task cannot promise zero downtime. The in-memory counter resets on replacement.

ACM renews an exportable certificate only after it has been exported at least once. The renewal event handler exports the new material, updates the TLS secret, and forces a new ECS deployment; duplicate renewal events with the same certificate do not redeploy. A daily check raises an alarm if the issued certificate has less than 30 days left. Check both CloudWatch error alarms because they have no notification action configured yet.

## Cost estimate

At the current Ohio task size and public IPv4 rate: about $12.66/month, plus two Secrets Manager secrets at about $0.80/month and one exportable ACM certificate at $7 per 198-day issuance or renewal (roughly $1.08/month averaged). Two standard CloudWatch alarms could add up to about $0.20/month if the free alarm allowance is exhausted. Total baseline is approximately **$14.54-$14.74/month** before taxes, credits, CloudWatch logs, or exceptional API usage. Cloudflare's Free plan can proxy this hostname and includes one rate limiting rule, but actual account plan and settings must be checked in its dashboard.
