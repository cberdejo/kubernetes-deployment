
# How To init with Terraform
Make sure to create `terraform.tfvars` following this [template](terraform/terraform.tfvars.example).
```bash
cd terraform

# 1. Initialise providers
tofu init

# 2. Preview what will be created
tofu plan -var-file=terraform.tfvars

# 3. Install everything (MetalLB → Envoy Gateway → Longhorn → Sealed Secrets → cert-manager + seal-credentials → todo-app)
tofu apply -var-file=terraform.tfvars

# 4. Add Gateway IP to /etc/hosts
kubectl get svc -n envoy-gateway
# Then add to /etc/hosts:  <EXTERNAL-IP>  todo.local longhorn.local
```

> **How sealing is automated:** `null_resource.seal_credentials` runs `seal-credentials.sh` via `local-exec` after the Sealed Secrets controller is ready. It runs in parallel with cert-manager (both depend on `sealed_secrets`), and `todo_app` waits for both before deploying. If you change a credential variable in `terraform.tfvars`, re-running `tofu apply` will re-seal and redeploy automatically.

---

## Teardown

```bash
tofu destroy -var-file=terraform.tfvars
```
