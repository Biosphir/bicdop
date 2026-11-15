# Bicdop v0.3.8

Bicdop (BIOSPHIR Integrated Command & Development Operations Platform) adalah aplikasi CLI dari BIOSPHIR untuk mengelola workspace, menandai folder proyek, menjalankan proyek Python, dan bekerja dengan Git serta GitHub.

Dokumen ini menjelaskan kode **repo lokal v0.3.8**. Nomor versi di repo, paket yang terpasang, dan rilis yang tersedia di GitHub bisa berbeda.

## Mulai menggunakan Bicdop

Bicdop memerlukan Python 3.10 atau lebih baru. Contoh Windows memakai Python 3.12. Dependensi runtime paketnya adalah `prompt-toolkit`. Git dibutuhkan untuk operasi Git, dan GitHub CLI (`gh`) dibutuhkan untuk koneksi GitHub.

Untuk memasang versi dari repo lokal, jalankan PowerShell dari folder yang berisi `pyproject.toml`:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
.\.venv\Scripts\bicdop.exe
```

Jika ingin memasang kode yang sudah tersedia di GitHub melalui pip, jalankan dari PowerShell. Ini memerlukan Git dan akses ke repo.

```powershell
py -3.12 -m pip install "git+https://github.com/Biosphir/bicdop.git"
bicdop
```

Jika pip berhasil tetapi PowerShell tidak mengenali `bicdop`, cek pesan pip untuk lokasi folder `Scripts` yang perlu ada di PATH, lalu buka terminal baru. Untuk instalasi di virtual environment, panggil executable lewat path seperti contoh di atas. Perintah uninstall paket adalah `py -3.12 -m pip uninstall bicdop`. Gunakan interpreter yang memasangnya.

### Antarmuka interaktif

- Ketik **`bicdop`** tanpa argumen di terminal. Ketik perintah yang memakai `--` langsung di dalam prompt Bicdop, misalnya `--help`. Bentuk `bicdop --help` di PowerShell akan ditolak pada versi ini.
- Header menampilkan versi paket, BIOSPHIR, workspace aktif, dan repo GitHub yang terhubung dengan checkout saat ini. Baris input menunjukkan direktori kerja Bicdop.
- Gulir panel riwayat dengan roda mouse di atas panel, **PgUp**, atau **PgDn**. Header tetap berada di atas. Proses yang perlu konfirmasi atau input terminal bisa sementara tampil di konsol biasa.
- Gunakan `exit` atau `quit` untuk kembali ke terminal.
- Nama sederhana bisa langsung ditulis, misalnya `--run Demo`. Kutip path, nama dengan spasi, dan pesan beberapa kata. Pisahkan beberapa target dengan koma pada perintah yang mendukungnya. Contoh `--stage app.py, "test app.py"`.
- Nama workspace dan direktori kerja adalah dua hal yang terpisah. `--select` mengubah workspace aktif. `--goto-workspace` memindahkan direktori kerja Bicdop.

## Referensi perintah

Notasi `[opsional]` di tabel menunjukkan argumen yang boleh dilewati. Kurung siku dan elipsis adalah notasi dokumentasi.

### Aplikasi

| Perintah | Perilaku |
| --- | --- |
| `--help` atau `-h` | Menampilkan perintah menurut kategori, termasuk contoh pemakaian. |
| `--version` | Menampilkan versi paket Bicdop yang sedang dijalankan. |
| `--update` | Memeriksa GitHub Release stabil dan meminta pip memasang paket dari tag yang lebih baru. |
| `exit` atau `quit` | Menutup sesi interaktif. |

### Workspace dan folder

| Perintah | Perilaku |
| --- | --- |
| `--set-workspace [folder]` | Mendaftarkan folder yang sudah ada dan langsung menjadikannya workspace aktif. Jika target dilewati, gunakan direktori kerja. Membuat marker di root workspace saja. |
| `--select WORKSPACE` | Mengaktifkan workspace tersimpan menurut nama. |
| `--set-name-workspace NAMA_BARU` | Mengganti nama workspace aktif di konfigurasi. Nama harus tanpa spasi dan belum digunakan oleh entri lain. |
| `--goto-workspace` | Berpindah ke folder workspace aktif. |
| `--projects` | Menampilkan tabel subfolder satu tingkat di workspace aktif. |
| `--show` | Menampilkan tabel subfolder satu tingkat di direktori kerja. |
| `--cd folder` | Masuk ke folder atau path yang diberikan di sesi Bicdop. |
| `--cd-back` | Naik satu tingkat ke direktori induk. |
| `--mkdir nama` | Membuat satu folder baru di direktori kerja. |
| `--set-name [folder] -to nama_baru` | Mengganti nama folder aktif jika argumen folder dilewati, atau mengganti nama subfolder langsung yang dipilih. |
| `--delete [folder, ...] [--no-confirm]` | Menghapus folder aktif jika target dilewati, atau menghapus satu atau beberapa subfolder langsung beserta isinya. Secara default meminta konfirmasi. |

Tabel `--show` dan `--projects` menampilkan kolom **Folder** dan **.bicdop**. Baris kuning berarti file marker belum ada. File biasa dilewati. Nama awal workspace berasal dari nama folder dengan spasi diganti tanda hubung. Jika ada dua root dengan nama bawaan yang sama, ubah nama workspace yang lama terlebih dahulu agar keduanya dapat disimpan. Setelah rename atau pemindahan folder workspace secara fisik, daftarkan kembali path yang baru.

`--delete` bersifat permanen. Target eksplisit dibatasi pada subfolder langsung, dan Bicdop menampilkan target sebelum konfirmasi. Gunakan `--no-confirm` hanya ketika daftar folder sudah dipastikan. Setelah menghapus folder aktif, direktori kerja pindah ke induknya jika operasi berhasil.

### Marker dan pengumpulan proyek

| Perintah | Perilaku |
| --- | --- |
| `--plant -here` | Membuat atau menyegarkan marker di folder aktif. |
| `--plant -all` | Menanam marker di folder aktif dan subfolder langsung. |
| `--plant folder` | Menanam marker pada satu folder yang sudah ada. |
| `--find .bicdop` | Mencari folder ber-marker secara rekursif dan menampilkan path lengkap. |
| `--collect [folder, ...] [--copy]` | Menampilkan rencana untuk memindahkan folder ber-marker dari luar workspace ke dalam workspace, lalu meminta konfirmasi. Dengan `--copy`, salin folder dan pertahankan sumbernya. |

`--find` memeriksa direktori kerja, workspace aktif, serta Documents, Desktop, dan Downloads pada profil pengguna jika tersedia. Pencarian menghindari direktori seperti `.git`, `.venv`, `node_modules`, dan `__pycache__`, serta melewati subfolder yang mengarah ke lokasi lain. Hasil di luar workspace ditandai kuning. Dengan workspace belum dipilih, semua hasil ditandai sebagai di luar workspace.

Dengan `--collect` tanpa target, Bicdop mengumpulkan hasil yang bisa dipindahkan dari luar workspace. Marker di dalam folder induk ikut bersama induknya. Target eksplisit dapat berupa nama atau path. Gunakan path lengkap dalam kutip jika nama ditemukan di beberapa lokasi. Bicdop menolak target yang sudah ada di workspace, sumber yang menaungi workspace atau direktori kerja, dan rencana dengan benturan nama tujuan. Pemindahan memakai rename pada filesystem yang sama. Gunakan `--copy` jika sumbernya ada di drive lain. Jalankan lagi dari direktori lain jika sumber adalah direktori kerja aktif atau induknya.

### Menjalankan proyek Python

Pencarian folder untuk perintah proyek mencoba subfolder direktori kerja terlebih dahulu, lalu subfolder workspace aktif. Path dalam kutip dapat menunjuk langsung ke folder.

| Perintah | Perilaku |
| --- | --- |
| `--info folder` | Tampilkan folder yang dipilih, lokasi marker, file utama, dan interpreter Python. |
| `--status folder` | Ringkasan file utama, environment Python, branch Git, dan jumlah perubahan. |
| `--doctor folder` | Periksa marker, file utama, serta apakah interpreter Python bisa dijalankan. |
| `--setup folder` | Buat atau pakai ulang `.venv` proyek yang sudah ditandai. Jika ada `requirements.txt`, minta konfirmasi sebelum menjalankan pip di environment proyek. |
| `--set-main FILE` | Tetapkan file Python utama untuk folder aktif. Gunakan path relatif di dalam proyek. |
| `--run folder` | Jalankan file Python utama dengan direktori kerja di root proyek. |
| `--test folder [-- argumen_pytest]` | Jalankan pytest. Argumen setelah `--` diteruskan ke pytest. Proyek perlu marker dan pytest yang terpasang di interpreter yang dipilih. |
| `--build folder` | Jalankan `python -m build` pada proyek dengan `pyproject.toml`. Perlu paket Python `build`. Artefak wheel dan source archive tersedia di `dist` setelah berhasil. |

Interpreter dipilih dengan urutan `.venv` proyek yang valid, lalu interpreter Bicdop jika `.venv` tidak ada. Jika `.venv` ada tetapi tidak lengkap, perbaiki atau pindahkan environment tersebut sebelum menjalankan `--setup` lagi. Build backend bisa memasang dependensi build di environment terisolasi saat build berjalan.

Contoh untuk proyek bernama Demo:

```text
--goto-workspace
--plant Demo
--info Demo
--setup Demo
--doctor Demo
--run Demo
--test Demo -- "tests/test_auth.py" -q
--build Demo
```

### Git dan GitHub

| Perintah | Perilaku |
| --- | --- |
| `--git-status [folder]` | Tampilkan branch, status tracking upstream yang diketahui lokal, dan daftar file yang berubah. Defaultnya checkout saat ini. |
| `--diff [--staged]` | Tampilkan perubahan belum staged pada file yang sudah dilacak, atau diff staged dengan `--staged`. |
| `--stage file, ...` | Tambahkan file yang dipilih secara eksplisit ke staging area Git. |
| `--commit "pesan"` | Tampilkan daftar staged dan minta konfirmasi sebelum commit. Pesan tidak boleh kosong. |
| `--set-github ["https://github.com/OWNER/REPO"]` | Tanpa URL, lakukan login GitHub jika diperlukan. Dengan URL, verifikasi akses lalu kaitkan repo dengan checkout lokal saat ini. |
| `--push` | Kirim commit dari branch lokal aktif ke branch dengan nama yang sama di repo GitHub yang terhubung. |
| `--pull` | Ambil branch dengan nama yang sama dari repo terhubung dan terima hanya perubahan fast-forward. Working tree harus bersih. |

Git lokal memerlukan identitas Git untuk commit. Bicdop mengecek staged tree lagi setelah konfirmasi. `--push` mengirim commit yang sudah ada. Ahead/behind menggunakan data tracking dari fetch terakhir. File baru yang belum dilacak terlihat di `--git-status`, dan diff-nya dapat dilihat setelah file di-stage.

Untuk menghubungkan repo, mulai dari clone lokal yang sudah ada. Bicdop menggunakan `gh auth login --web` jika GitHub CLI belum login. `gh` menangani autentikasi, dan Bicdop menyimpan URL serta path checkout. Koneksi disimpan per checkout sehingga berpindah folder di dalam Bicdop juga bisa mengganti repo yang terlihat di header. Untuk menjalankan push atau pull, aktifkan branch lokal dan berada di checkout yang sudah terhubung. Jika checkout dipindah, jalankan `--set-github` lagi dari lokasi baru.

```text
--cd "C:\Projects\Demo"
--set-github "https://github.com/OWNER/REPO"
--git-status
--diff
--stage app.py, "test app.py"
--diff --staged
--commit "Update validation"
--push
```

## Data yang disimpan

### Marker proyek

Nama file marker adalah `.bicdop`. File ini disimpan di root folder yang ditandai. Contoh isinya:

```json
{
  "folder_name": "Demo",
  "folder_path": "C:\\Projects\\Demo",
  "main_file": "src/app.py"
}
```

- `folder_name` dan `folder_path` menyimpan nama serta path folder saat marker ditulis. Bicdop menggunakan lokasi folder aktual saat mencari atau menjalankan proyek.
- `main_file` adalah path relatif ke file `.py` di dalam proyek. Marker baru memilih `main.py` jika tersedia, atau menyimpan `null` jika belum ditemukan. Marker kosong atau lama tanpa field itu dapat memakai `main.py` bila file tersebut ada. Gunakan `--set-main` untuk menetapkan file tertentu.
- Rename, move, dan copy melalui Bicdop menyegarkan informasi lokasi pada marker. Jika folder dipindah atau di-rename lewat File Explorer, jalankan `--plant -here` di folder baru untuk menyegarkan JSON.
- Marker tidak memakai ID proyek. Field `folder_id` lama dihapus saat marker JSON ditulis ulang. Bicdop mempertahankan field tambahan lain yang ada.

### Konfigurasi akun Windows

| File | Isi |
| --- | --- |
| `%LOCALAPPDATA%\bicdop\workspace.json` | Workspace aktif dan daftar workspace yang disimpan. |
| `%LOCALAPPDATA%\bicdop\github.json` | Pemetaan path checkout ke URL repo GitHub. Format satu koneksi dari versi sebelumnya dapat dibaca. |

Di luar Windows, kode memakai `$XDG_CONFIG_HOME/bicdop` jika variabelnya tersedia, atau `~/.config/bicdop`. Marker berada di dalam proyek. Saat menguji setup dari awal, cadangkan konfigurasi pengguna jika registry dan koneksi lama masih diperlukan.

## Rilis dan pembaruan

`--update` dijalankan dari prompt Bicdop. Updater membaca GitHub Release stabil terbaru pada repo `Biosphir/bicdop` dan membandingkan tag dengan versi paket terpasang. Jika tag lebih tinggi, Bicdop memasang arsip sumber dari tag itu lewat pip. Instalasi per-user tetap memakai cakupan yang sama.

Untuk menjadikan perubahan tersedia lewat updater, versi di `pyproject.toml` harus cocok dengan tag stabil, misalnya `0.3.8` dengan `v0.3.8`. Pastikan tag menunjuk ke commit yang memuat perubahan yang akan dirilis. Push commit ke branch utama saja tidak menghasilkan update. Di Windows, ketika updater memulai pemasangan, Bicdop menutup sesi supaya pip bisa memperbarui launcher. Tunggu pip selesai, buka Bicdop lagi, lalu lihat versi di header atau jalankan `--version`.

## Struktur repo untuk pengembangan

| File atau folder | Tanggung jawab |
| --- | --- |
| `pyproject.toml` | Nama paket, versi, dependensi, dan entry point `bicdop`. |
| `src/biosphir_cli/cli.py` | Parser argumen, header, dispatch perintah, dan pemilihan folder proyek. |
| `src/biosphir_cli/prompt.py` | Antarmuka terminal layar penuh, pewarnaan input, tokenisasi, dan guliran riwayat. |
| `src/biosphir_cli/help_view.py` | Isi referensi perintah yang tampil lewat `--help`. |
| `src/biosphir_cli/workspace.py` | Konfigurasi workspace, daftar folder, dan pencarian marker. |
| `src/biosphir_cli/folders.py` | Navigasi, pembuatan, rename, delete, dan collect folder. |
| `src/biosphir_cli/markers.py` | Pembacaan dan pembaruan marker serta validasi file utama. |
| `src/biosphir_cli/project.py` | Pemilihan Python, setup, doctor, status, test, dan build. |
| `src/biosphir_cli/github.py` | Koneksi GitHub per checkout, autentikasi, push/pull, dan operasi Git lokal. |
| `src/biosphir_cli/updater.py` | Pemeriksaan rilis dan pembaruan paket pip. |
| `tests/test_github.py` | Tes otomatis koneksi GitHub dan pemilihan checkout dengan proses eksternal yang disimulasikan. |
| `packaging/` | Berkas build installer Windows dari eksperimen sebelumnya. Alur instalasi yang dipakai saat ini adalah paket Python lewat pip. |

Untuk development, dari repo yang sudah memiliki `.venv`:

```powershell
.\.venv\Scripts\python.exe -m pip install -e ".[test]"
.\.venv\Scripts\python.exe -m pytest -q
```

## Batas cakupan untuk Alice

Gunakan isi dokumen ini sebagai rujukan perintah yang tersedia di snapshot lokal. Sepuluh kandidat fitur lanjutan sempat dibahas dan dibatalkan sebelum selesai. Mereka belum menjadi command Bicdop. Integrasi GitHub yang tersedia mencakup perintah di tabel Git dan GitHub. Fitur seperti `--unstage`, `--git-history`, `--fetch`, `--branch`, `--switch-branch`, `--open`, `--workspaces`, `--init-project`, `--task`, `--logs`, dan `--check-markers` belum tersedia.

Operasi lokal sudah pernah diuji di proyek sementara, termasuk setup environment, run/test/build, diff, stage, dan commit. Login browser dan transfer ke GitHub sungguhan belum diverifikasi. Tes repo saat ini terutama mencakup koneksi GitHub dengan simulasi, dan tidak menggantikan pengujian endpoint publik atau pengalaman terminal pengguna.
