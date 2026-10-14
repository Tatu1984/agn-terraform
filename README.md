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
IAM group **`pigeonpulse-deployers`** with **`iam/terraform-deployer-policy.json`** attached; one IAM user per person in that group:

| Service | Why | Scope |
|---|---|---|
| EC2 | security groups, key pair, instance, Elastic IP, tags | us-west-2 only |
| RDS | Postgres instance, final snapshot on destroy | us-west-2 only |
| S3 | create media bucket, bucket policy, public-access block | buckets `pigeonpulse-*` |
| CloudFront | distribution + origin access control | account (global service) |
| IAM | create the app server role/instance profile, attach **only** `AmazonSSMManagedInstanceCore`, pass role **only** to EC2 | roles/profiles `pigeonpulse-*` |
| SSM | start SSH sessions **only** to instances tagged `Project=pigeonpulse`; end own sessions | us-west-2 |
| S3 state | read/write `pigeonpulse-tfstate-*` objects (shared Terraform state) | that bucket |
| STS | `GetCallerIdentity` | — |

Members **cannot** create IAM users/roles, touch other buckets, or act outside us-west-2 for EC2/RDS.

### 2. Created by Terraform (no human action)
- **App server role `pigeonpulse-ec2`**: S3 `ListBucket` on the media bucket, `Get/Put/DeleteObject` on its objects; SSM core (browser shell). The app has **no stored AWS keys**.
- **CloudFront → S3**: bucket policy lets only this distribution read objects; bucket stays fully private.
- **Network**: `pigeonpulse-web` SG — 80/443 only; **no port 22** (SSH goes through SSM). `pigeonpulse-db` SG — 5432 from web SG only; RDS not public.
- **State bucket** `pigeonpulse-tfstate-<account>`: private, versioned, `prevent_destroy`.

### 3. Outside AWS
| What | Needed for |
|---|---|
| Neon direct DB URL, R2 endpoint + keys (read) | `migrate-data.yml`, one time |
| Current Vercel env values (`BETTER_AUTH_SECRET`, PayPal, Pusher, Windy, `CRON_SECRET`) | `.env` |
| DNS access for `pigeon-pulse.com` | A record → Elastic IP (later) |
| PayPal dashboard | webhook URL → `https://pigeon-pulse.com/api/payment/paypal/webhook` (after DNS) |

## Prerequisites (each person's machine — Mac/Linux, Windows via WSL)
- Terraform ≥ 1.6 (`brew install hashicorp/tap/terraform`), Ansible (`pipx install --include-deps ansible`)
- AWS CLI v2 + [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- Your own IAM user's access key in `~/.aws/credentials` as profile `pigeonpulse`, then `export AWS_PROFILE=pigeonpulse`
- Your SSH public key in `ansible/group_vars/all/main.yml` → `team_ssh_keys`
- The vault password in `~/.config/pigeonpulse/vault-pass` (from the team password manager; never in chat/git)

## Add a teammate
1. **Client (console)**: create IAM user → add to group `pigeonpulse-deployers` (no direct policies). Teammate creates their own access key.
2. **Existing member**: append the teammate's SSH **public** key to `team_ssh_keys`, commit, push, run `site.yml`. Share the vault password via password manager.
3. **Teammate**: install prerequisites, clone this repo, then:
   ```bash
   cd terraform && terraform init && terraform apply   # no changes expected; writes ansible/inventory.ini + terraform.yml locally
   cd ../ansible && ansible-playbook site.yml --vault-password-file ~/.config/pigeonpulse/vault-pass
   ssh -o ProxyCommand="aws ssm start-session --region us-west-2 --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p" ubuntu@<instance-id>
   ```
**Remove someone**: delete their key from `team_ssh_keys` + run `site.yml`; client removes their IAM user.

## Run order

```bash
# 1. Infra (~10 min, RDS is the slow part)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set media bucket name
terraform init && terraform apply
# writes ../ansible/inventory.ini and ../ansible/group_vars/all/terraform.yml (DB password, 0600)

# 2. Secrets
cd ../ansible
cp group_vars/all/secrets.yml.example group_vars/all/secrets.yml   # fill in
ansible-vault encrypt group_vars/all/secrets.yml

# 3. Data (pick a quiet window: writes to Neon after this are lost)
ansible-playbook migrate-data.yml --vault-password-file ~/.config/pigeonpulse/vault-pass
#    check the printed row counts vs Neon, and that restore output has no TABLE DATA errors

# 4. App
ansible-playbook site.yml --vault-password-file ~/.config/pigeonpulse/vault-pass
#    open http://<public_ip>  (plain HTTP until DNS)
```

### Going live on pigeon-pulse.com
1. DNS: A record `pigeon-pulse.com` → `terraform output public_ip` (Cloudflare: grey cloud / DNS only).
2. `ansible/group_vars/all/main.yml`: `domain: pigeon-pulse.com`.
3. Set `NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_AUTH_BASE_URL` to `https://pigeon-pulse.com` in `pigeon_pulse/.github/workflows/docker-image.yml`, push, wait for the build, then `ansible-playbook site.yml --vault-password-file ~/.config/pigeonpulse/vault-pass`; Caddy fetches the cert.
4. PayPal webhook URL, mobile app API URL (`agn-mobile`: `eas.json`, `service/api.service.ts`, `app/(app)/liberation.tsx`), then retire Vercel.
5. Keep Neon + R2 ~2 weeks for rollback, then delete; remove migration keys from `secrets.yml`.

### Deploying app updates
```bash
# Push to main → GitHub Actions builds the image (~3 min) → then:
cd ansible && ansible-playbook site.yml --vault-password-file ~/.config/pigeonpulse/vault-pass   # pulls image, restarts only if changed
# Roll back: add -e app_tag=<commit-sha>
```

## Notes
- Terraform state lives in S3 (`versions.tf` backend, lockfile prevents concurrent applies). It contains the DB password — the bucket is private to the deployers group.
- Fresh account: comment out the `backend "s3"` block, `terraform apply` (creates the state bucket), restore the block, `terraform init -migrate-state`.
- RDS has deletion protection + 7-day backups; `terraform destroy` fails until protection is turned off (intentional).
- `sslmode=no-verify` in DB URLs: TLS on, CA check off (RDS CA isn't in Node's trust store).
- Fresh empty DB can't run the app's migration chain (`20260309_schema_cleanup`); always restore from Neon first.
- `site.yml` runs the daily cron inside the app container (09:00 UTC), replacing Vercel cron.
