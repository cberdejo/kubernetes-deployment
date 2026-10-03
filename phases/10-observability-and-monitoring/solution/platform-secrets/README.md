# platform-secrets

Encrypted `SealedSecret` manifests for the platform services. Generate them with:

```bash
./scripts/seal-platform-secrets.sh
```

The script writes `authentik-secrets.yaml`, `harbor-secrets.yaml` and
`grafana-oidc-{authentik,monitoring}.yaml` here. They are encrypted with the cluster's
Sealed Secrets public key, so they are safe to commit.

`namespaces.yaml` creates the namespaces these secrets go into: the platform and
monitoring layers, which deploy authentik, Harbor and Grafana, depend on this one, so
their namespaces must exist before the SealedSecrets are applied.

This folder intentionally has **no `kustomization.yaml`**: the `platform-secrets`
Flux Kustomization generates one with every manifest it finds, so any new sealed file
you add is applied without editing a resource list.

> The blobs only decrypt in a cluster holding the same Sealed Secrets private key.
> Back it up with `scripts/backup-sealed-secrets-key.sh` (see tasks.md, Step 6).

## The files in this repository are not yours

The sealed files committed here were sealed with the author's cluster key. In your
cluster they are just ciphertext that no key can open: the controller reports
`no key could decrypt secret` and authentik, Harbor and Grafana wait for their Secrets.

That is expected. Seal your own credentials (Step 6 of tasks.md, or let
`bootstrap.sh` do it), commit the new files over these ones, and push. From then on
they are bound to *your* key, and your key backup keeps them valid across rebuilds.
