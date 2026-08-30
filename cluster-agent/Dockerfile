# The cluster's agent. Small on purpose: it holds the deployment's platform
# credential, so everything in here is something that credential is worth
# risking.
FROM alpine:3.20

RUN apk add --no-cache bash curl jq ca-certificates

# Pinned rather than latest. A client that changes under us is a cluster whose
# agent stops working on a Tuesday for reasons nobody changed.
ARG KUBECTL_VERSION=v1.30.4
ARG TARGETARCH=amd64
RUN curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client=true --output=yaml >/dev/null

COPY agent.sh /usr/local/bin/caytu-cluster-agent
RUN chmod +x /usr/local/bin/caytu-cluster-agent

# Not root. It needs the Kubernetes API and the node's metadata service, and
# neither wants a root user in the container to reach them.
RUN adduser -D -u 10001 caytu
USER 10001

ENTRYPOINT ["/usr/local/bin/caytu-cluster-agent"]
