# hello-api-go

Aplikasi hidup di: https://hello-api-go-dev.thankfulisland-969918a9.southeastasia.azurecontainerapps.io (environment dev; container berhenti saat tidak ada trafik, request pertama setelah idle butuh beberapa detik).

API Go satu endpoint yang dideploy ke **Azure Container Apps** lewat **GitHub Actions**, dengan infrastruktur sebagai kode (**Bicep**), image di **Azure Container Registry**, dan autentikasi pipeline ke Azure lewat **OIDC** tanpa menyimpan rahasia.

Alurnya meniru pola backend Adhara (auth-service, customer-service): setiap merge ke branch `ci/development` otomatis menjalankan test, build image, lalu deploy.

## Arsitektur

```
 developer ──push──▶ GitHub (ci/development)
                        │
                        ▼ GitHub Actions (OIDC, tanpa secret statis)
        ┌───────────────┼──────────────────┬──────────────────┐
        ▼               ▼                  ▼                  ▼
      test            infra            build-push           deploy
  go vet/test   az deployment group   docker build       az containerapp
  bicep lint    (infra/main.bicep)    push ke ACR         update --image
                        │                  │                  │
                        ▼                  ▼                  ▼
            ┌──────────────────── Azure: rg-hello-api-go-dev ────────────────────┐
            │  Log Analytics ◀── Container Apps Environment ── Container App     │
            │  Azure Container Registry ◀── AcrPull ── User-assigned Identity    │
            └────────────────────────────────────────────────────────────────────┘
                                                             │
                                            https://hello-api-go-dev.<hash>.<region>.azurecontainerapps.io
```

## Layanan Azure yang dipakai dan alasannya

| Layanan                        | Peran                                                      | Alasan                                                                                       |
| ------------------------------ | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Azure Container Apps           | Menjalankan container, ingress HTTPS, autoscale 0..N       | Serverless container tanpa mengelola cluster; padanan ringan dari AKS/Helm di Adhara         |
| Azure Container Registry       | Menyimpan image hasil pipeline                             | Registry privat di dalam Azure, tarik image lewat identitas tanpa password                   |
| User-assigned Managed Identity | Identitas container app untuk `AcrPull`                    | Tidak ada kredensial registry yang disimpan di app maupun pipeline                           |
| Log Analytics                  | Log stdout/stderr container dan metrik environment         | Observability bawaan Container Apps; query dengan KQL di portal                              |
| Microsoft Entra app + OIDC     | Identitas GitHub Actions, role terbatas di resource group  | Federated credential: GitHub menukar token OIDC ke Azure, tanpa client secret di GitHub      |
| Bicep                          | Mendefinisikan semua resource di atas                      | IaC resmi Azure, idempoten, dijalankan pipeline sehingga infra ikut ter-review lewat PR      |

## Endpoint

| Method | Path      | Keterangan                                        |
| ------ | --------- | ------------------------------------------------- |
| GET    | `/`       | `{"message":"Hello World","environment":"dev",…}` |
| GET    | `/health` | `{"status":"OK"}`, dipakai probe readiness/liveness |

Port dari env `PORT` (default 3000), nama environment dari `APP_ENV`.

## Pipeline (`.github/workflows/ci-development.yml`)

| Job          | Isi                                                                                                   |
| ------------ | ----------------------------------------------------------------------------------------------------- |
| `test`       | gofmt, go vet, go test, lint Bicep. Satu-satunya job yang jalan untuk pull request.                   |
| `infra`      | `az deployment group create` dengan `infra/main.bicep`. Idempoten; image yang sedang jalan dipertahankan. |
| `build-push` | Build Dockerfile, push ke ACR dengan tag `<sha8>` dan `development`, cache layer di GitHub.          |
| `deploy`     | `az containerapp update --image <acr>/hello-api-go:<sha8>` lalu smoke test `/health` dan `/`.        |

Padanan dengan Adhara: `.gitlab-ci.yml` + template global ⇄ workflow ini; `CONTAINER_REGISTRY` OCIR ⇄ ACR; Helm upgrade ⇄ `az containerapp update`; `READINESS_PATH: /health` ⇄ probe di Bicep.

## Setup sekali jalan

1. Buat repo GitHub `hello-api-go`, push branch `main` dan `ci/development`.
2. Buka https://shell.azure.com (Bash), unggah `infra/bootstrap.sh`, jalankan:

   ```
   bash bootstrap.sh <github-owner> hello-api-go dev
   ```

   Skrip hanya membuat yang tidak bisa dibuat pipeline sendiri: resource group `rg-hello-api-go-dev` dan app registration GitHub dengan federated credential untuk branch `ci/development` dan environment `development`, role Contributor + User Access Administrator terbatas di resource group itu. Nilai `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` dicetak di akhir.
3. Di GitHub: Settings → Secrets and variables → Actions, isi tiga secret itu. Settings → Environments, buat `development`.
4. Push ke `ci/development`. Run pertama membuat ACR, environment, identity, container app (image quickstart), lalu mengganti ke image hasil build. URL tercetak di summary job `deploy`.

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

## Biaya

Container Apps consumption plan punya kuota gratis bulanan (180.000 vCPU-detik, 360.000 GiB-detik, 2 juta request); `minReplicas: 0` untuk dev membuat container berhenti saat tidak ada trafik. ACR Basic sekitar USD 5 per bulan, Log Analytics gratis sampai 5 GB per bulan. Hapus semuanya dengan `az group delete --name rg-hello-api-go-dev`.

## Pengembangan berikutnya

- Environment `prod` dengan parameter `environmentName=prod` (min 1 replica, max 3) dan approval manual di environment GitHub.
- Application Insights lewat OpenTelemetry untuk trace dan metrik aplikasi.
- Key Vault untuk rahasia aplikasi, dibaca lewat managed identity yang sama.
- Custom domain dan sertifikat terkelola di Container Apps.
