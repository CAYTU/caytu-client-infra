# Access modes

How a deployment is reached is four independent choices, not one. A LAN box can
hold a real certificate; a public host can be reached by bare IP; Windows changes
the commands but not the topology. Collapsing them into a single "region" field
is what produced instance records pointing at hostnames nobody had registered.

| Axis | Question | Values |
|---|---|---|
| `resolution` | How do clients find it? | `caytu-dns`, `customer-dns`, `ip`, `hosts-file`, `mdns` |
| `tls` | Who issues and terminates the certificate? | `letsencrypt-http`, `letsencrypt-dns`, `byo`, `self-signed`, `none` |
| `edge` | What proxies to the stack? | `bundled-nginx`, `iis`, `external-proxy` |
| `hostPlatform` | What is the host? | `linux-docker`, `windows-docker-desktop`, `windows-wsl2`, `macos-docker` |

## Combinations that cannot work

Validate these before provisioning; each one fails at a different point and none
of them fails clearly.

- **`letsencrypt-http` behind NAT.** HTTP-01 needs inbound `:80` from the public
  internet. Behind NAT the challenge times out. Use `letsencrypt-dns`, which
  proves control through a DNS record and never needs inbound.
- **`letsencrypt-*` with `resolution: ip`.** Public CAs do not issue for bare IP
  addresses. Use `self-signed` or `byo`.
- **`letsencrypt-*` with `hosts-file` or `mdns`.** The CA cannot resolve a name
  that only exists on the LAN.
- **`edge: iis` with `bundled-nginx` ports.** Both want `:80`/`:443`. When IIS is
  the edge, the stack must publish to loopback only and let IIS own the ports.
- **`tls: none` on anything reachable from outside the LAN.** Session cookies
  and the API token cross the wire in clear.

## What the operator has to do, by combination

### resolution: `hosts-file`

Every client machine needs an entry. There is no server-side fix.

```
# Linux, macOS:  /etc/hosts
# Windows:       C:\Windows\System32\drivers\etc\hosts   (edit as Administrator)
10.0.1.42   caytu.internal
```

Windows caches aggressively: `ipconfig /flushdns` after editing. macOS:
`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.

### resolution: `mdns`

Works out of the box on macOS and modern Linux (avahi). Windows needs Bonjour
installed, which is often blocked by policy. Prefer `hosts-file` on Windows
fleets.

### tls: `self-signed`

The certificate must be imported into each client's trust store, or every
browser shows an interstitial and API clients refuse outright.

```
# Windows (Administrator):
certutil -addstore -f "ROOT" caytu.crt

# macOS:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain caytu.crt

# Debian/Ubuntu:
sudo cp caytu.crt /usr/local/share/ca-certificates/caytu.crt
sudo update-ca-certificates
```

Firefox keeps its own store and ignores the OS one: import through
`about:preferences` → Privacy & Security → View Certificates.

`caytu-client ssl self-signed <host-or-ip>` generates it with the address as both
IP and DNS SAN, which is what lets it work when `resolution` is `ip`.

### tls: `letsencrypt-dns`

The only ACME mode that works behind NAT. Needs credentials for the DNS provider
holding the zone, scoped to writing TXT records on that zone and nothing else.

### edge: `iis`

Windows Server fronting the stack. IIS owns `:80`/`:443`; the compose stack
publishes to loopback.

1. Install **URL Rewrite** and **Application Request Routing**.
2. IIS Manager → server node → **Application Request Routing Cache** → Server
   Proxy Settings → tick **Enable proxy**.
3. Install the **WebSocket Protocol** Windows feature. Without it the live video
   and telemetry sockets fail while ordinary pages work, which is a confusing
   way to find out.
4. Add a reverse-proxy rule to `http://localhost:5100`.
5. Raise `maxAllowedContentLength`; the default 30 MB rejects recording uploads.

```xml
<rewrite>
  <rules>
    <rule name="caytu" stopProcessing="true">
      <match url="(.*)" />
      <action type="Rewrite" url="http://localhost:5100/{R:1}" />
      <serverVariables>
        <set name="HTTP_X_FORWARDED_PROTO" value="https" />
      </serverVariables>
    </rule>
  </rules>
</rewrite>
```

`X-Forwarded-Proto` matters: without it the app builds `http://` URLs behind an
HTTPS edge and browsers block them as mixed content.

### edge: `external-proxy`

The customer's nginx, Apache, Traefik, Caddy or hardware load balancer. Same
requirements as IIS: forward `X-Forwarded-Proto` and `X-Forwarded-For`, allow
WebSocket upgrade, and raise the body-size limit.

Point it at the bundled nginx on loopback rather than at the backend directly.
Provisioning sets `NGINX_HTTP_BIND=127.0.0.1:8080` when `edge` is `iis` or
`external-proxy`, so the two never fight for `:80`, and the customer's proxy
needs one rule instead of restating our routing. That matters most for
`/api/config`, which is served by the frontend even though it sits under
`/api/`: a proxy sending all of `/api/` to the backend breaks the login page,
and pointing at our nginx means theirs never has to know.

### hostPlatform: `windows-docker-desktop`

- Bind mounts need drive sharing enabled in Docker Desktop settings.
- `host.docker.internal` resolves; the Linux gateway address does not.
- Line endings: a `.env` saved CRLF gives values with a trailing `\r`, which
  produces errors that look nothing like their cause. Keep the repo `LF`.

### hostPlatform: `windows-wsl2`

Put the repo **inside** the WSL2 filesystem, not on `/mnt/c`. Bind mounts across
the boundary are slow enough to fail health checks, and inotify does not fire, so
watch mode silently does nothing.

## Firewall

Whatever the edge, only it should be exposed. The stack's own published ports
(backend 5100, frontend 3100, mongo 27117, redis 6479, minio 9400/9401) are for
the host itself and should not be reachable from the network.
