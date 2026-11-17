# hello-api-go

API Go satu endpoint untuk latihan alur deploy otomatis ala Adhara, dengan target Azure Container Apps: Dockerfile multi-stage, pipeline dipicu branch `ci/development`, image dipush ke registry, lalu container app diperbarui ke image baru.

## Endpoint

| Method | Path      | Keterangan                           |
| ------ | --------- | ------------------------------------ |
| GET    | `/`       | `{"message":"Hello World", ...}`     |
| GET    | `/health` | `{"status":"OK"}`, dipakai readiness |

Port dari env `PORT` (default 3000), nama environment dari `APP_ENV`.

## Jalankan lokal

```
go test ./...
go run .
curl http://localhost:3000/
```

Dengan Docker:

```
docker build -t hello-api-go .
docker run --rm -p 3000:3000 hello-api-go
```

## Alur deploy (`.github/workflows/ci-development.yml`)

Padanan `.gitlab-ci.yml` + template global di auth-service dan customer-service:

| Adhara (GitLab CI)                     | Repo ini (GitHub Actions)                                  |
| -------------------------------------- | ---------------------------------------------------------- |
| Pipeline jalan saat `ci/development`   | `on.push.branches: [ci/development]`                       |
| Build image dari Dockerfile            | job `build-push` (docker/build-push-action)                |
| Push ke `sin.ocir.io/.../mch/<image>`  | Push ke `ghcr.io/<owner>/hello-api-go`                     |
| Helm upgrade ke cluster Kubernetes     | job `deploy`: `az containerapp update --image <image>`     |
| `READINESS_PATH: /health`              | curl `/health` setelah deploy                              |
| `SERVICE_PORT: 3000`                   | `--target-port 3000`, env `PORT=3000`                      |

Job berjalan berurutan: `test` (vet + test) → `build-push` (tag `<sha8>` dan `development`) → `deploy`. Pull request ke `ci/development` hanya menjalankan `test`.

Login ke Azure memakai OIDC (federated credential), jadi tidak ada password atau client secret yang disimpan di GitHub.

## Setup sekali jalan

1. Buat repo GitHub `hello-api-go`, push branch `main` dan `ci/development`.
2. Jalankan pipeline sekali agar image `ghcr.io/<owner>/hello-api-go:development` terbentuk (job deploy akan gagal karena resource Azure belum ada, itu wajar).
3. Di GitHub, buka Packages → `hello-api-go` → Package settings → ubah visibility ke **Public** supaya Azure bisa menarik image tanpa kredensial.
4. Buka https://shell.azure.com (Bash), unggah `infra/azure-setup.sh`, lalu:

   ```
   bash azure-setup.sh <github-owner> hello-api-go
   ```

   Skrip membuat resource group `rg-hello-api-go-dev`, environment Container Apps, container app `hello-api-go-dev` (0 sampai 1 replica, 0,25 vCPU), identitas Entra untuk GitHub OIDC dengan role Contributor di resource group itu, dan mencetak tiga nilai secret.
5. Isi secret di GitHub (Settings → Secrets and variables → Actions): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
6. Buat environment GitHub bernama `development` (Settings → Environments). Job deploy memakai environment ini; di sini juga bisa ditambah approval manual kalau mau.
7. Push commit apa pun ke `ci/development`. Pipeline akan test, build, deploy, lalu mencetak URL `https://hello-api-go-dev.<hash>.southeastasia.azurecontainerapps.io`.

## Biaya

Container Apps consumption plan punya kuota gratis bulanan (180.000 vCPU-detik, 360.000 GiB-detik, 2 juta request). Dengan `--min-replicas 0` aplikasi berhenti saat tidak ada trafik, sehingga latihan ini praktis gratis. GHCR gratis untuk image public.

## Branch

- `main`: stabil.
- `ci/development`: setiap merge ke sini memicu test, build image, dan deploy ke Azure.
