# Caytu-hosted deployments

How a machine goes from "New instance" in the console to a working site on
`<name>.caytu.link`. Nobody touches the box at any point.

## What happens, in order

1. **The platform dispatches `Provision.yml`.** It holds no AWS credential, so it
   starts a workflow instead. Inputs are the instance id, region, subdomain and
   platform URL. Nothing comes from the request body.
2. **Terraform builds the machine.** One EC2 instance, an EIP, a Route53 A
   record for `<subdomain>.caytu.link`, and an instance role. State is per
   deployment, at `instances/<id>/terraform.tfstate`, so one destroy can never
   touch another customer.
3. **`bootstrap.sh` runs from user_data.** It installs docker and the AWS CLI,
   writes `/etc/caytu-client/deployment.env`, fetches the agent from S3 and
   checks its sha256, then sets up a timer that keeps a docker login to ECR
   fresh.
4. **The machine enrols itself.** It sends its signed EC2 identity document to
   the platform, which returns an org-scoped token. No credential is ever put in
   user_data.
5. **The agent claims the deployment** and writes what it needs into
   `compose/.env.onprem`: the image tag, the registry, the domain, the API URL.
6. **The stack comes up.** Ten containers. nginx serves plain HTTP first,
   because it has no certificate yet.
7. **A certificate is issued.** The agent waits until the hostname reaches this
   machine, then runs certbot over HTTP-01, pins nginx to the real domain and
   reloads. The deployment reports itself running.

## Where things are, on the machine

| Path | What |
| --- | --- |
| `/etc/caytu-client/deployment.env` | Which deployment this is. Written before anything can fail. |
| `/opt/caytu-client/` | The agent and the compose files. |
| `/opt/caytu-client/compose/.env.onprem` | Everything the stack reads. |
| `/opt/caytu-client/compose/certbot/conf/live/<host>/` | The certificate. |
| `/usr/local/bin/caytu-ecr-login` | Refreshed by a timer every 6h. |

The agent runs as a container (`compose-provisioner-agent-1`) with the docker
socket. It has no AWS CLI, so anything needing AWS runs on the host instead.

## Debugging

Reach the machine with SSM, not SSH:

```sh
AWS_PROFILE=eks-admin aws ssm send-command --region us-east-1 \
  --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters 'commands=["docker ps -a --format \"{{.Names}} | {{.Status}}\""]'
```

Things worth checking, in the order they usually break:

- `cat /etc/caytu-client/deployment.env` tells you if the machine knows what it
  is. If this is missing, bootstrap failed early.
- `docker logs compose-provisioner-agent-1` shows enrolment and provisioning.
  Repeated 404s mean it is talking to the wrong platform.
- `grep -E "^(IMAGE_REGISTRY|CAYTU_BILLINGS_URL|NEXT_PUBLIC_API_URL)=" .env.onprem`
  covers the three values that have caused the most trouble.
- `docker logs compose-nginx-1` is where you find out the site is not being
  served at all. It crash-loops if pointed at a certificate that does not exist.
- `curl -s https://<host>/api/config` shows what the browser is told. If this
  returns the backend's 503, the request is being sent to the wrong service.

A deployment can report itself running while serving nothing. `status: running`
means compose started, not that the site works.

## Things that bite

- **Only `us-east-1` works.** Our images live in one region and the agent pulls
  from the registry in its own region. See issue #19.
- **The API base URL is the origin, with no `/api` on the end.** The client
  prepends `/api` itself.
- **`NEXT_PUBLIC_*` in the browser comes from a script tag in the page**, not
  from the build. The server reads the env at request time and embeds it.
- **The agent writes files as root.** It runs in a container, so anything it
  writes has to keep the deploy user's ownership.
- **Let's Encrypt limits count per registered domain**, so every
  `*.caytu.link` deployment shares one allowance. Set `CAYTU_ACME_STAGING=1`
  when testing heavily.

## Not done yet

- The encrypted secret store is never seeded, so a hosted deployment cannot be
  licensed and refuses every request except auth. Issue #28.
- `clientSocketUrl` and `clientMinioUrl` still point at localhost, so realtime
  and object storage will not work from a browser.
- The host's platform token is written to `.env` in plaintext. Issue #4.
