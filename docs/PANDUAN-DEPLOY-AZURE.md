# Panduan lengkap: deploy otomatis ke Azure dari GitHub

Catatan ini menuliskan semua langkah yang benar-benar dijalankan sampai pipeline `hello-api-go` hijau dan aplikasi hidup di Azure Container Apps, termasuk semua kesalahan yang muncul di tengah jalan dan perbaikannya. Ditulis supaya orang lain bisa mengulang dari nol tanpa kejutan.

Hasil akhir: push atau merge ke branch `ci/development` → GitHub Actions menjalankan test → membuat/memperbarui infrastruktur Azure dengan Bicep → build image Docker dan push ke Azure Container Registry → memperbarui Container App → smoke test. Tidak ada langkah manual setelah setup awal.

## 0. Yang dibutuhkan

| Kebutuhan | Keterangan |
| --- | --- |
| Akun GitHub | Repo public atau private, keduanya bisa |
| Akun Azure dengan subscription aktif | Lihat bagian 1, ini bagian yang paling sering macet |
| Go 1.23+ di laptop | Hanya untuk menjalankan dan mengetes lokal, pipeline tidak bergantung padanya |
| Browser | Semua langkah Azure dikerjakan lewat portal dan Cloud Shell, tidak perlu memasang Azure CLI di laptop |

Tidak perlu Docker Desktop, Azure CLI, maupun GitHub CLI di laptop. Semua build terjadi di runner GitHub, semua perintah Azure dijalankan di Cloud Shell (terminal di browser).

## 1. Akun Azure dan subscription

Ini langkah yang menghabiskan waktu paling banyak. Yang terjadi dan yang dipelajari:

1. Daftar di https://azure.microsoft.com/free lewat tombol **Try Azure for free** (bukan tombol Sign up pay-as-you-go di sebelahnya). Free account memberi kredit USD 200 selama 30 hari plus layanan gratis 12 bulan. Pay-as-you-go tetap mendapat layanan gratis bulanan dan 12 bulan, hanya tanpa kredit.
2. Login dengan akun Microsoft. Email Gmail bisa dipakai. Kalau halaman "Enter your password" muncul padahal belum pernah daftar, pilih **Create one!** di bawah kolom email.
3. Formulir: hanya kotak persetujuan "I agree to the terms" yang wajib dicentang; tiga kotak lain opsional.
4. Verifikasi kartu. Pelajaran penting:
   - Microsoft **menolak kartu debit virtual dan kartu fintech atau prepaid**. Pesan errornya selalu sama dan tidak informatif: "Check that the details in all fields are correct or try a different card". Kartu debit Jago dan kartu debit bank konvensional tertentu ditolak dengan pesan itu walau transaksi internasional sudah aktif.
   - Yang paling aman: kartu kredit bank konvensional atas nama sendiri. Ada otorisasi sementara USD 1 yang dikembalikan.
   - Beberapa percobaan gagal berturut-turut bisa memicu pesan **"You're not eligible for an Azure free account"**. Ini keputusan sistem risiko Microsoft, support tidak membatalkannya. Jalan keluarnya: coba pay-as-you-go dengan kartu kredit, Azure for Students kalau punya email kampus, atau pakai subscription teman (ditambahkan sebagai Contributor + User Access Administrator di resource group).
   - Jangan pernah menempelkan nomor kartu dan CVV ke chat atau catatan.
5. Setelah berhasil, portal menampilkan "Let's start building". Pastikan menu **Subscriptions** menampilkan satu subscription berstatus Active (nama default "Azure subscription 1"). Tanpa subscription, Cloud Shell dan semua resource tidak bisa dibuat.

## 2. Repo GitHub dan branch

1. Buat repo kosong di https://github.com/new (tanpa README, .gitignore, license).
2. Dari folder proyek:

   ```
   git remote add origin https://github.com/<owner>/hello-api-go.git
   git push -u origin main ci/development
   ```

   Push pertama memicu dialog login Git Credential Manager di browser.
3. Dua branch yang dipakai: `main` untuk kode stabil, `ci/development` sebagai pemicu deploy. Hanya push ke `ci/development` yang menjalankan deploy; pull request ke branch itu hanya menjalankan job `test`.

Setelah push pertama, pipeline sudah jalan dan hijau walau Azure belum siap: job `preflight` memeriksa apakah tiga secret `AZURE_*` ada; kalau belum, job `infra`, `build-push`, dan `deploy` dilewati (skipped), bukan gagal.

## 3. Bootstrap di Azure Cloud Shell

Hanya dua hal yang tidak bisa dibuat pipeline sendiri: resource group dan identitas untuk GitHub. Keduanya dibuat sekali oleh `infra/bootstrap.sh`.

1. Buka https://shell.azure.com, pilih **Bash**. Pilih subscription, dan **No storage account required** (sesi sementara cukup).
2. Peringatan "Subscription ... is not registered to Microsoft.CloudShell Namespace" normal untuk subscription baru. Hilangkan dengan `az provider register --namespace Microsoft.CloudShell`.
3. Upload `infra/bootstrap.sh` lewat ikon Upload/Download files di toolbar, lalu:

   ```
   bash bootstrap.sh <github-owner> hello-api-go dev
   ```

   Skrip diam 2 sampai 5 menit di awal karena `az provider register --wait`; itu bukan hang. Yang dibuat:
   - resource group `rg-hello-api-go-dev` di `southeastasia`;
   - registrasi provider `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.OperationalInsights`, `Microsoft.ManagedIdentity`;
   - app registration Entra `github-hello-api-go-dev` plus service principal, role **Contributor** dan **User Access Administrator** terbatas di resource group itu (yang kedua agar Bicep boleh memberi role AcrPull ke managed identity);
   - federated credential OIDC untuk branch `ci/development` dan environment GitHub `development`.
4. Di akhir tercetak `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. Salin.

Skrip aman dijalankan berulang; yang sudah ada tidak dibuat dua kali.

### Masalah yang muncul di sini dan sudah diperbaiki di skrip

**a. Subject OIDC GitHub berubah format.** Run pertama gagal di `azure/login` dengan:

```
AADSTS700213: No matching federated identity record found for presented assertion subject
'repo:dionisbalan27@93642006/hello-api-go@1462099007:environment:development'
```

GitHub kini menyertakan ID pemilik dan ID repo di subject claim (`owner@id/repo@id`), sedangkan bootstrap versi awal mendaftarkan `repo:owner/repo:...` tanpa ID. Azure mencocokkan subject persis, jadi tidak ketemu. Versi skrip sekarang membaca kedua ID dari API publik GitHub dan mendaftarkan empat subject (dengan dan tanpa ID). Kalau menjalankan skrip versi lama, perbaikannya manual:

```
APP=<AZURE_CLIENT_ID>
OBJ=$(az ad app show --id $APP --query id -o tsv)
for S in "repo:<owner>@<ownerId>/<repo>@<repoId>:environment:development" \
         "repo:<owner>@<ownerId>/<repo>@<repoId>:ref:refs/heads/ci/development"; do
  az ad app federated-credential create --id $OBJ --parameters "{\"name\":\"$(echo $S | tr ':/@' '---')\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$S\",\"audiences\":[\"api://AzureADTokenExchange\"]}" -o none
done
az ad app federated-credential list --id $OBJ --query "[].subject" -o tsv
```

Nilai `ownerId` dan `repoId` terlihat di log step `azure/login` yang gagal, atau dari `https://api.github.com/users/<owner>` dan `https://api.github.com/repos/<owner>/<repo>` (field `id`).

**b. Provider `Microsoft.ManagedIdentity` belum terdaftar.** Run berikutnya gagal di Bicep dengan `MissingSubscriptionRegistration ... Microsoft.ManagedIdentity`. Bootstrap awal hanya mendaftarkan tiga provider. Perbaikan: `az provider register --namespace Microsoft.ManagedIdentity --wait` di Cloud Shell, dan skrip sekarang menyertakannya.

**c. Pipeline tidak boleh mendaftarkan provider sendiri.** Percobaan menaruh `az provider register` di workflow gagal, karena registrasi provider adalah aksi level subscription sedangkan identitas GitHub hanya punya hak di resource group. Workflow sekarang hanya memeriksa dan memberi peringatan; registrasi tetap tugas pemilik subscription lewat bootstrap.

## 4. Secret dan environment di GitHub

1. Repo → Settings → Secrets and variables → Actions → **New repository secret**, tiga kali: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` dengan nilai dari bootstrap. Ketiganya hanya pengenal, bukan rahasia; tidak ada password atau client secret di mana pun karena login memakai OIDC.
2. Repo → Settings → Environments → **New environment** bernama `development`. Tidak perlu isi apa pun. Nama ini harus sama dengan `environment: development` di workflow dan dengan subject federated credential.

## 5. Menjalankan pipeline

Push apa pun ke `ci/development`, misalnya commit kosong:

```
git checkout ci/development
git commit --allow-empty -m "ci: trigger deployment"
git push origin ci/development
```

Atau di tab Actions buka run terakhir dan klik **Re-run all jobs** (tombol ada di dalam halaman run, kanan atas, bukan di daftar run).

Urutan job dan durasi pada run pertama:

| Job | Isi | Durasi pertama |
| --- | --- | --- |
| `test` | gofmt, go vet, go test, `az bicep build` | ± 1 menit |
| `preflight` | cek tiga secret ada | detik |
| `infra` | `az deployment group create` dengan `infra/main.bicep` | 3 sampai 4 menit |
| `build-push` | docker build, push ke ACR tag `<sha8>` dan `development` | ± 1 menit |
| `deploy` | `az containerapp update --image ...`, lalu curl `/health` dan `/` | 1 sampai 2 menit |

Run berikutnya lebih cepat karena infra sudah ada (Bicep idempoten) dan cache layer Docker tersimpan di GitHub.

Cara membaca hasil: halaman run menampilkan lima kotak job; klik kotak untuk log per step. Setelah `deploy` hijau, tab Summary menampilkan kotak "Deployed" berisi image dan URL aplikasi `https://hello-api-go-dev.<hash>.southeastasia.azurecontainerapps.io`.

Membaca log lewat API GitHub tanpa login dibatasi 60 permintaan per jam; kalau memantau dengan skrip, beri jeda 30 detik atau lebih.

## 6. Apa yang dibuat di Azure

Semua di resource group `rg-hello-api-go-dev`, didefinisikan di `infra/main.bicep`:

| Resource | Nama | Peran |
| --- | --- | --- |
| Log Analytics workspace | `log-hello-api-go-dev` | log container dan metrik |
| Azure Container Registry (Basic) | `acrhelloapigo<hash>` | menyimpan image, admin user mati |
| User-assigned managed identity | `id-hello-api-go-dev` | identitas container app, role AcrPull di ACR |
| Container Apps environment | `cae-hello-api-go-dev` | lingkungan jalan container |
| Container App | `hello-api-go-dev` | ingress HTTPS port 3000, probe `/health`, scale 0 sampai 1 |

Di Entra ID: app registration `github-hello-api-go-dev` dengan empat federated credential.

## 7. Siklus kerja setelah setup

Ubah kode di branch fitur → pull request ke `ci/development` (job test jalan) → merge → beberapa menit kemudian versi baru hidup di URL yang sama. Tidak ada langkah manual.

Untuk environment `prod`: jalankan `bootstrap.sh <owner> <repo> prod`, buat environment GitHub `production`, dan salin workflow dengan `ENVIRONMENT: prod` dan branch pemicu `main`. Bicep sudah membedakan replica untuk prod (min 1, max 3).

## 8. Biaya dan pembersihan

- Container Apps consumption plan: kuota gratis bulanan 180.000 vCPU-detik, 360.000 GiB-detik, 2 juta request. Dengan min replica 0, container berhenti saat tidak ada trafik.
- ACR Basic sekitar USD 5 per bulan; untuk akun baru, tier Standard gratis 12 bulan.
- Log Analytics gratis sampai 5 GB per bulan.
- Pasang budget alert di Cost Management → Budgets, misalnya USD 5.
- Hapus semuanya: `az group delete --name rg-hello-api-go-dev --yes` di Cloud Shell, lalu hapus app registration di Entra ID → App registrations.

## 9. Ringkasan kesalahan dan perbaikannya

| Gejala | Penyebab | Perbaikan |
| --- | --- | --- |
| "try a different card" saat daftar | kartu debit virtual atau fintech ditolak | kartu kredit bank konvensional, atau pakai subscription teman |
| "You're not eligible for an Azure free account" | terlalu banyak percobaan gagal atau identitas dianggap pernah terdaftar | pay-as-you-go dengan kartu kredit, Azure for Students, atau subscription teman |
| `bash bootstrap.sh` diam lama | `az provider register --wait` di subscription baru | tunggu sampai 5 menit |
| azure/login: `AADSTS700213 No matching federated identity record` | subject OIDC GitHub kini `owner@id/repo@id` | daftarkan federated credential dengan format baru (sudah di skrip) |
| Bicep: `MissingSubscriptionRegistration Microsoft.ManagedIdentity` | provider belum terdaftar | `az provider register --namespace Microsoft.ManagedIdentity --wait` (sudah di skrip) |
| step "Prepare Azure CLI" gagal 25 detik | pipeline mencoba mendaftarkan provider tanpa hak subscription | workflow hanya memeriksa; registrasi oleh pemilik |
| Tombol Re-run tidak ketemu | ada di dalam halaman run, bukan di daftar | atau push commit kosong ke `ci/development` |
| Kotak Contributors di GitHub menampilkan nama lain | cache tampilan setelah riwayat ditulis ulang | hilang sendiri; API contributors sudah benar |
