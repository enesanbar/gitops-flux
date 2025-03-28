# Cert Issuer

Replace the root certificates with your own certificates in [cert-manager](infrastructure/cert-manager/mkcert-ca-secret.yaml) to issue local certificates for testing

```bash
mkcert -install

kubectl -n cert-manager create secret tls mkcert-ca-key-pair \
--key "$(mkcert -CAROOT)"/rootCA-key.pem \
--cert "$(mkcert -CAROOT)"/rootCA.pem

kubectl -n cert-manager get secret mkcert-ca-key-pair -oyaml > infrastructure/cert-manager/mkcert-ca-secret.yaml
```
