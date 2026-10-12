# Pigeon Pulse Infra

Terraform provisions AWS (us-west-2). Ansible configures the server, deploys the app, and runs the one-time Neon/R2 → AWS data copy.

```
terraform/   EC2 t4g.small + Elastic IP, RDS Postgres, S3 + CloudFront, IAM role, security groups
ansible/     site.yml (setup + deploy, re-run to ship), migrate-data.yml (one-time)
iam/         least-privilege policy for whoever runs Terraform
```

Cost ≈ $33–38/mo (EC2 ~17.5, RDS ~14, S3/CloudFront/transfer ~0–5).

## Permissions needed

### 1. From the client (AWS account owner)
An IAM user (or SSO role) for the operator with **`iam/terraform-deployer-policy.json`** attached:

| Service | Why | Scope |
|---|---|---|
| EC2 | security groups, key pair, instance, Elastic IP, tags | us-west-2 only |
| RDS | Postgres instance, final snapshot on destroy | us-west-2 only |
| S3 | create media bucket, bucket policy, public-access block | buckets `pigeonpulse-*` |
| CloudFront | distribution + origin access control | account (global service) |
| IAM | create the app server role/instance profile, attach **only** `AmazonSSMManagedInstanceCore`, pass role **only** to EC2 | roles/profiles `pigeonpulse-*` |
| STS | `GetCallerIdentity` | — |

The operator **cannot** create other IAM users/roles, touch other buckets, or act outside us-west-2 for EC2/RDS. Client creates access keys for that user (or grants console + CloudShell).

Optional: `ssm:StartSession` + `ssm:TerminateSession` if the operator should use the browser shell (EC2 → Connect → Session Manager).

### 2. Created by Terraform (no human action)
- **App server role `pigeonpulse-ec2`**: S3 `ListBucket` on the media bucket, `Get/Put/DeleteObject` on its objects; SSM core (browser shell). The app has **no stored AWS keys**.
- **CloudFront → S3**: bucket policy lets only this distribution read objects; bucket stays fully private.
- **Network**: `pigeonpulse-web` SG — 80/443 from anywhere, 22 from `ssh_cidrs` only. `pigeonpulse-db` SG — 5432 from web SG only; RDS not public.

### 3. Outside AWS
| What | Needed for |
|---|---|
| GitHub read access to `infps/pigeon_pulse` from **your** SSH key (agent-forwarded, nothing stored on server) | `site.yml` clone/pull |
| Neon direct DB URL, R2 endpoint + keys (read) | `migrate-data.yml`, one time |
| Current Vercel env values (`BETTER_AUTH_SECRET`, PayPal, Pusher, Windy, `CRON_SECRET`) | `.env` |
| DNS access for `pigeon-pulse.com` | A record → Elastic IP (later) |
| PayPal dashboard | webhook URL → `https://pigeon-pulse.com/api/payment/paypal/webhook` (after DNS) |

## Prerequisites (operator machine)
- Terraform ≥ 1.6, Ansible ≥ 2.15 (`pipx install ansible-core`)
- AWS credentials for the deployer user: `export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…` (or `AWS_PROFILE`)
- SSH key loaded in agent (`ssh-add`) and added to GitHub

## Run order

```bash
# 1. Infra (~10 min, RDS is the slow part)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set bucket name + your IP/32
terraform init && terraform apply
# writes ../ansible/inventory.ini and ../ansible/group_vars/all/terraform.yml (DB password, 0600)

# 2. Secrets
cd ../ansible
cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml   # fill in
ansible-vault encrypt group_vars/all/secrets.yml

# 3. Data (pick a quiet window: writes to Neon after this are lost)
ansible-playbook migrate-data.yml --ask-vault-pass
#    check the printed row counts vs Neon, and that restore output has no TABLE DATA errors

# 4. App
ansible-playbook site.yml --ask-vault-pass
#    open http://<public_ip>  (plain HTTP until DNS)
```

### Going live on pigeon-pulse.com
1. DNS: A record `pigeon-pulse.com` → `terraform output public_ip` (Cloudflare: grey cloud / DNS only).
2. `ansible/group_vars/all/main.yml`: `domain: pigeon-pulse.com`.
3. Set `NEXT_PUBLIC_AUTH_BASE_URL=https://pigeon-pulse.com` in `pigeon_pulse/.github/workflows/docker-image.yml`, push, wait for the build, then `ansible-playbook site.yml --ask-vault-pass`; Caddy fetches the cert.
4. PayPal webhook URL, mobile app API URL (`agn-mobile`: `eas.json`, `service/api.service.ts`, `app/(app)/liberation.tsx`), then retire Vercel.
5. Keep Neon + R2 ~2 weeks for rollback, then delete; remove migration keys from `secrets.yml`.

### Deploying app updates
```bash
# Push to main → GitHub Actions builds the image (~3 min) → then:
cd ansible && ansible-playbook site.yml --ask-vault-pass   # pulls image, restarts only if changed
# Roll back: add -e app_tag=<commit-sha>
```

## Notes
- Terraform state is **local** and contains the DB password — don't lose it, don't commit it. Move to an S3 backend if more than one person runs apply.
- RDS has deletion protection + 7-day backups; `terraform destroy` fails until protection is turned off (intentional).
- `sslmode=no-verify` in DB URLs: TLS on, CA check off (RDS CA isn't in Node's trust store).
- Fresh empty DB can't run the app's migration chain (`20260309_schema_cleanup`); always restore from Neon first.
- `site.yml` runs the daily cron inside the app container (09:00 UTC), replacing Vercel cron.
