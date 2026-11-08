# Yorpersonal YouTube Subscriptions Hub

Aplikasi **Personal YouTube Subscriptions Hub** berbasis **Flutter** (Web/Desktop/Android) dan **Python FastAPI + SQLite** dengan tampilan YouTube Dark Mode (`#0F0F0F`). Menampilkan video khusus dari daftar channel yang di-subscribe tanpa gangguan algoritma rekomendasi luar.

## Fitur Utama

- **Sidebar Subscriptions (3 Mode)**: Mode Penuh (`240px`), Mode Ikon Mini (`72px`), dan Mode Sembunyi (`0px`).
- **Grid 3 Video per Baris** (Laptop) & **1 Kolom** (HP), dilengkapi informasi lengkap:
  - Thumbnail `16:9` + Durasi Video
  - Judul Video, Nama Channel, Jumlah Views, Waktu Upload Relatif (`menit/jam/hari/bulan/tahun lalu`), dan Jumlah Likes (`👍`)
- **Urutan & Filter Lengkap**:
  - Urutkan berdasarkan: **🔥 View Terbanyak**, **👍 Like Terbanyak**, **🕒 Waktu Upload**
  - Rentang Waktu: **Semua Waktu**, **Minggu Ini**, **Bulan Ini**, **Tahun Ini**, serta kotak input **`[ N ] Tahun Lalu`** (ketik angka misal `2`, `3`, `5` tahun lalu)
  - **Slider 2 Lingkaran Filter Durasi (`0 Menit` – `2 Jam+`)** dengan akurasi per 1 menit
- **Navigasi Tab Halaman (Dropdown + Tombol Kiri/Kanan)** & **Penyimpanan Permanen Jumlah Video per Tab (`25` / `50` / `100 Video`)**
- **Unsubscribe via Titik 3 (`⋮`) dengan Tekan & Tahan (`Hold 1.5 Detik`)** + Opsi **Mode Cepat 10 Menit** bebas konfirmasi
- **Tombol `Refresh YouTube` Manual di Latar Belakang (`0%`–`100%`)**:
  - Warna **Merah**: Belum di-refresh (klik untuk mulai sync seluruh channel di background dengan lingkaran persentase `0%`–`100%` tanpa menghentikan aktivitas)
  - Warna **Hijau (`100%`)**: Sync selesai, klik untuk langsung menampilkan video-video terbaru ke layar
- **Export & Import Daftar Channel Excel/CSV** (`daftar_channel_youtube.csv`)

## Cara Menjalankan

Klik 2x file `jalankan.bat`, atau jalankan manual melalui terminal:

```bash
# 1. Jalankan Backend Python (Port 8000)
cd backend
pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000

# 2. Jalankan Frontend Flutter (Opsional jika ingin mode dev)
cd frontend
flutter run -d chrome
```

