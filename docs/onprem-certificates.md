# Certificates on a machine we do not own

The hosted path gets a certificate the easy way: we own `caytu.link`, we create
the DNS record, the machine has a public IP and inbound `:80`, so HTTP-01 works
every time. None of that is true on-premise, and this decides what replaces it
before there is code shaped around the wrong answer.

## The choice

`access.tls` already offers five values. The question is which of them is the
path we build for and support, and which are the edges.

**Self-signed on a fixed address is the default**, and it is what a record gets
when nobody chooses anything. **Bring-your-own is the first upgrade from it**,
for a site with a hostname and an internal PKI. Let's Encrypt over DNS-01 is
supported for a named short list of providers. HTTP-01 stays for the sites that
genuinely have inbound `:80`, which is a minority.

The default is not a preference, it is the only thing that works on the shape
these sites arrive in. An on-premise deployment is a box on a customer's LAN
reached by its own address. That needs no DNS record and no hosts entry on every
client machine, and no public CA will issue for a bare address, so Let's Encrypt
there is not awkward but impossible.

Everything above self-signed is optional, and none of it sits on the path a site
takes to working. That ordering is the point: the default has to stand up
unattended on a LAN, and each other mode is something a site opts into once it
has a reason to.

## Why not DNS-01 as the default

DNS-01 is the obvious answer to "HTTP-01 needs a port we will not get", and it
is a real option, but it is the wrong thing to build first.

It needs a credential that can write TXT records on the customer's production
zone, living on a box we shipped them. That is a security review at every
customer large enough to have an on-premise requirement in the first place, and
security reviews are measured in weeks. Bring-your-own asks for no credential
at all.

It is not one integration. Certbot needs a different plugin package and a
different credentials file for route53, cloudflare, digitalocean, google,
azure, and each one has to be tested against a zone we do not own. The
`dnsProvider` field on the record makes this look like a lookup table. It is
five integrations.

It does not cover the sites that most need on-premise. A hospital or a factory
running Windows AD DNS, or a DNS appliance with no API, cannot do DNS-01 at
all. Neither can an air-gapped site, which cannot reach the ACME server. For
those, bring-your-own is not a fallback, it is the only thing that works.

## Why bring-your-own

It is what enterprise IT already does. A site with an internal PKI issues
certificates as routine work and would rather do that than create an API
credential for a vendor appliance. A site with a commercial wildcard already
has the files.

It needs nothing from the network. No inbound port, no outbound reach to an
ACME server, no DNS provider. It works air-gapped, which nothing else here
does.

The machinery mostly exists. `ssl bring-your-own` already puts files in the
place nginx reads, and that path is the same one Let's Encrypt and self-signed
use, on purpose. What it lacks is validation and renewal watching, which is a
day of work rather than five integrations.

## What that costs, and what we do about it

Renewal becomes the customer's problem, and a certificate that expires quietly
is worse than one that was never issued: the site simply stops working one
morning and nobody knows why. So the deployment has to watch its own
certificate and say so early, in the console, where somebody is looking.

That is the real work bring-your-own creates, and it is worth doing regardless:
a self-signed certificate expires too, and so does a Let's Encrypt one when
renewal has been silently failing for two months.

## Build order

1. **Make the default real.** A record with nothing chosen means a LAN box on
   its own address with a certificate it signs itself, on the platform and on
   the host alike. Nothing else matters until a site can be stood up with no
   decisions made.
2. **Dispatch on the record.** Provisioning reads `access.tls` and does the
   right thing for each value instead of always attempting HTTP-01. Sites
   choosing `byo` or `none` stop failing an ACME attempt they never wanted.
3. **Harden bring-your-own.** Check the key matches the certificate, that it
   covers the hostname, and that it is not already expired, before it goes
   anywhere near nginx. Installing a mismatched pair crash-loops nginx and
   takes the site down, which is a bad way to find out.
4. **Watch expiry and report it.** Days remaining goes to the platform with the
   rest of the deployment's state, so the console can warn before it matters.
   This is the one piece the default does not get for free: a self-signed
   certificate is good for ten years, so nothing here is urgent until a site
   brings its own.
5. **DNS-01 for route53 and cloudflare.** Two providers, named explicitly,
   rather than a field that implies we support whatever anyone types.

HTTP-01 needs no work. It already runs, and a site with inbound `:80` is
exactly the case it was written for.

## What this means for the record

Nothing changes in the model. All five `tls` values stay, and the four axes stay
independent. `letsencrypt-dns` becomes valid only for the providers we have
actually built, which is a validation rule rather than a schema change, and
refusing a provider we cannot serve is better than accepting one and issuing
nothing.

See [access-modes.md](access-modes.md) for the combinations that cannot work
at all, which is a separate list from this one.
