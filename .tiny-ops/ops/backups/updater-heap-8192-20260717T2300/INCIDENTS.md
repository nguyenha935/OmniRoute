# OmniRoute trên Tiny — Nhật ký sự cố và bài học bắt buộc

File này lưu những sự cố vận hành đã được xác nhận để agent không lặp lại cách
làm gây gián đoạn hệ thống.

## 2026-07-17 — Full test làm Tiny nghẽn

### Tác nhân

Đã chạy:

```bash
omniroute-patch test fix/provider-flow-consistency
```

Script `/opt/omniroute/ops/patch.sh` tự chạy `npm ci` khi thiếu dependency, sau
đó chạy lint toàn dự án, unit suite, Vitest, coverage và production build. Tổng
khối lượng hơn 15.000 test cộng build đã làm Tiny cạn tài nguyên/nghẽn, SSH và
Tailscale host gián đoạn, đồng thời Termix trả 502.

### Khôi phục đã xác nhận

- Dừng các tiến trình test/build còn lại; không reboot Tiny.
- Khôi phục riêng `tailscaled` của host qua đường quản trị Docker/Dockge khi SSH
  chưa vào được.
- Termix có Tailscale riêng. Sau khi `termix-tailscale` hoạt động lại, container
  `termix` còn bám network namespace cũ; `docker restart termix` đã khôi phục
  endpoint. Chi tiết nằm tại `/opt/termix/OPERATIONS.md`.
- Sau khôi phục phải xác nhận tải hệ thống, RAM available, không còn tiến trình
  test/build, `tailscaled` active, `omniroute` active và Termix trả HTTP 200.

### Cách test bản vá đã xác nhận an toàn

Bản vá `fix/provider-flow-consistency` được kiểm tra bằng đúng bốn test mục tiêu,
Node heap 1536 MB và `--test-concurrency=1`; kết quả 41/41 pass. Lint chỉ chạy
trên file thay đổi. Không chạy coverage hoặc production build trong pha test.

Mẫu lệnh:

```bash
DISABLE_SQLITE_AUTO_BACKUP=true node --max-old-space-size=1536 \
  --import tsx/esm \
  --import ./open-sse/utils/setupPolyfill.ts \
  --import ./tests/_setup/isolateDataDir.ts \
  --test --test-concurrency=1 \
  tests/unit/provider-connection-status.test.ts \
  tests/unit/playground-model-qualify.test.ts \
  tests/unit/providers-page-utils.test.ts \
  tests/unit/opencode-noauth-models-route.test.ts
```

### Cách chuẩn bị và deploy đã được thực hiện kỹ

1. Mỗi bản vá ở worktree riêng; đọc file liên quan, sửa theo pattern upstream,
   chạy test mục tiêu, commit rồi tạo snapshot có checksum.
2. Merge upstream mới vào từng worktree và giải quyết conflict tại chính branch
   bản vá; không sửa production để né conflict.
3. Chạy `update-omniroute --check` và duyệt target commit cùng patch-set hash.
4. Chạy `--preflight` với đúng hai pin; production chưa bị đụng ở bước này.
5. Chỉ deploy bằng `--update` với cùng pin. Updater build candidate đúng một lần
   trong cgroup giới hạn tài nguyên, smoke-test, backup package/data/config,
   swap nguyên tử và rollback khi health gate thất bại.
6. Sau deploy dùng `--verify-runtime` và kiểm tra các dịch vụ liên quan.

### Quy tắc không được lặp lại

- Không chạy `omniroute-patch test` trên Tiny.
- Không chạy full test, coverage hoặc build thủ công để test một thay đổi nhỏ.
- Không chạy nhiều test/build song song.
- Không deploy khi preflight còn conflict hoặc pin đã thay đổi.
- Không chữa sự cố tải bằng reboot host, sửa DNS hoặc thay cấu hình ứng dụng
  khác khi chưa xác định đúng nguyên nhân.
