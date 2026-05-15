# Fleetman Microservices

Base kustomization for the Fleetman application.

## Overlay Requirements

Overlays **must** provide the following environment-specific resources:

### Storage (required)

The MongoDB deployment references a PVC named `mongo-pvc` in namespace `fleetman-microservices`.
Your overlay must provide this PVC with an appropriate StorageClass for the target environment.

| Environment | Example                                      |
|-------------|----------------------------------------------|
| Local/Kind  | hostPath PV with `standard` StorageClass     |
| AWS         | EBS-backed PVC with `cloud-ssd` StorageClass |

### Ingress (required)

The webapp service needs an Ingress resource. Your overlay should define:
- Hostname appropriate for the environment
- TLS configuration and cert-manager issuer
- IngressClass (typically `nginx`)

## Example overlay kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../../../../components/fleetman-microservices  # base
- storage.yaml   # REQUIRED: PVC + StorageClass/PV
- ingress.yaml   # REQUIRED: environment-specific ingress
```

