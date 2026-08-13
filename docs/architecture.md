# Architecture

What the pieces are, where they run, and who talks to whom.

## The three sides

The platform never touches a customer machine. It asks a pipeline to build one,
and the machine reports back. That is the whole shape.

```mermaid
flowchart LR
  subgraph platform["Platform (Caytu-Infra)"]
    console["Console<br/>web-v2"]
    billings["billings<br/>instance records"]
    auth["auth<br/>enrolment, tokens"]
  end

  subgraph pipeline["Pipeline (this repo)"]
    gha["GitHub Actions<br/>Provision, Destroy, Power"]
    tf["Terraform<br/>state per deployment"]
  end

  subgraph machine["The machine (one per deployment)"]
    agent["agent<br/>claims and provisions"]
    stack["the stack<br/>10 containers"]
  end

  console --> billings
  billings -- "workflow_dispatch" --> gha
  gha --> tf
  tf -- "creates" --> machine
  agent -- "signed identity document" --> auth
  auth -- "org token" --> agent
  agent -- "state, steps, licence" --> billings
```

The platform holds no AWS credential. It starts a named workflow with fixed
inputs, and that workflow already has the credentials every other pipeline uses.
A service that can create EC2 instances is worth attacking. One that can start a
workflow is much less interesting.

## Provisioning, in order

```mermaid
sequenceDiagram
  participant C as Console
  participant B as billings
  participant G as GitHub Actions
  participant M as Machine
  participant A as auth

  C->>B: create instance
  B->>G: dispatch Provision.yml
  G->>G: terraform apply
  G->>M: EC2 + EIP + DNS record
  M->>M: bootstrap.sh, fetch agent from S3
  M->>A: signed identity document
  A-->>M: org-scoped token
  M->>B: claim the deployment
  M->>M: pull images, start the stack
  M->>M: certbot over HTTP-01
  M->>B: running, 100%
```

Each step can fail without the previous ones unwinding. A machine that cannot
enrol stays up so somebody can look at it, rather than tearing itself down.

## On the machine

```mermaid
flowchart TB
  subgraph host["EC2 instance"]
    direction TB
    boot["/etc/caytu-client/deployment.env<br/>which deployment this is"]
    timer["caytu-ecr-login.timer<br/>refreshes the registry login"]

    subgraph docker["docker"]
      agent["provisioner-agent<br/>has the docker socket"]
      nginx["nginx :80 :443"]
      front["frontend :3000"]
      back["backend :5000"]
      db[("mongodb")]
      rest["redis, minio, coturn,<br/>signaling, mqtt-streamer,<br/>gstreamer"]
    end
  end

  browser["Browser"] -- "https" --> nginx
  nginx -- "/" --> front
  nginx -- "/api/" --> back
  nginx -- "= /api/config" --> front
  back --> db
  agent -- "docker compose" --> docker
  timer --> agent
```

Two things about that picture are easy to get wrong.

`/api/config` goes to the **frontend**, not the backend. It is how the browser
is told where the API lives. It sits under `/api/`, so the general rule would
send it to the backend, which has no such route.

The agent runs in a container and drives the host's docker. So bind mounts in
the compose files are resolved by the **host**, which is why the repo is mounted
at its own path rather than at `/repo`.

## Who holds what

| Thing | Where it lives | Why there |
| --- | --- | --- |
| Instance record | billings | The platform owns what exists. |
| Enrolled host and token | auth | The platform owns who may talk to it. |
| Terraform state | S3, per deployment | One destroy can never touch another customer. |
| Deployment identity | the machine, `/etc/caytu-client` | Written before anything can fail. |
| Platform token | the machine, `.env` | Should be in the secret store. Issue #4. |
| Images | ECR, `us-east-1` only | Issue #19. |

## Trust

The machine proves what it is with the EC2 identity document AWS signs for it.
Nothing secret is put in `user_data`, so a leaked copy of it grants nothing.

```mermaid
flowchart LR
  imds["IMDS<br/>document + rsa2048 signature"] --> agent
  agent -- "POST /api/auth/enroll/instance" --> auth
  auth -- "verify against the AWS<br/>RSA-2048 certificate" --> check{"signed by AWS?<br/>our account?<br/>launched recently?"}
  check -- "no" --> refuse["refused, recorded<br/>on the deployment"]
  check -- "yes" --> token["org-scoped token"]
```

The organization is read from the instance record, never from the request. A
genuine machine presenting a real document could otherwise name any
organization and be given its token.
