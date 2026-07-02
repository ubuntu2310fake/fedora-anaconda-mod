# Fedora Anaconda Installer Runtime Patcher (Mod)

Một bộ công cụ "chắp vá" (Monkey Patching) thời gian thực can thiệp trực tiếp vào bộ cài Anaconda WebUI của Fedora trên môi trường Live CD[cite: 2, 3]. Dự án này cho phép tùy biến sâu quy trình cài đặt hệ điều hành mà không cần phải build lại các gói RPM phức tạp[cite: 2].

## 🚀 Tính năng chính

- **Bypass NVMe Format (`pyanaconda` & `blivet`):** Can thiệp vào hệ thống import hook của Python (`sys.meta_path`) để đánh lừa bộ cài, giữ nguyên phân vùng và filesystem hiện có trên ổ đĩa `nvme0n1` mà không làm mất dữ liệu cũ[cite: 2].
- **Bẻ khóa Giao diện (`Cockpit WebUI`):** Hạ cấp chính sách Content Security Policy (CSP)[cite: 2], sử dụng `MutationObserver` để liên tục theo dõi và giải phóng nút "Reformat" bị khóa bởi React DOM[cite: 2].
- **Hệ thống phục hồi dữ liệu tự động:** Cho phép cấu hình ánh xạ các thư mục sao chép (Post-install Custom Data Copy) bằng giao diện trực quan trực tiếp trên Wizard cài đặt, tự động chạy ngầm sau khi OS mới thiết lập xong[cite: 2].

## 📂 Cấu trúc dự án

* `patch.sh`: Script tổng hợp tự động hóa quy trình chèn mã độc lập trên Live CD[cite: 2].
* `pyanaconda/__init__.py`: Mã nguồn vá lỗi Python backend (Monkey patch blivet/anaconda)[cite: 2].
* `injected_script.js`: Script thao túng DOM Frontend và inject UI custom[cite: 2].

## 🛠️ Hướng dẫn sử dụng nhanh

Khởi động vào Fedora Live CD, mở Terminal và chạy các lệnh sau:

```bash
# Tải script patch về môi trường Live
curl -O [https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/patch.sh](https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/patch.sh)

# Cấp quyền và chạy với quyền root
chmod +x patch.sh
sudo ./patch.sh

# Khởi chạy bộ cài Fedora đã được mod
liveinst
