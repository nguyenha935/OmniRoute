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
5. Sau sự cố build ngày 2026-07-18, không còn build candidate trên Tiny. Tạo
   deployment-only branch bất biến từ request đã pin để GitHub-hosted
   `ubuntu-24.04` build, duyệt response/manifest SHA cùng attestation và exact
   run provenance, chạy artifact-aware preflight rồi mới `--update` với toàn bộ
   pins. Tiny chỉ verify, smoke-test, backup, swap và rollback.
6. Sau deploy dùng `--verify-runtime` và kiểm tra các dịch vụ liên quan.

### Quy tắc không được lặp lại

- Không chạy `omniroute-patch test` trên Tiny.
- Không chạy full test, coverage hoặc build thủ công để test một thay đổi nhỏ.
- Không chạy nhiều test/build song song.
- Không deploy khi preflight còn conflict hoặc pin đã thay đổi.
- Không chữa sự cố tải bằng reboot host, sửa DNS hoặc thay cấu hình ứng dụng
  khác khi chưa xác định đúng nguyên nhân.

## 2026-07-17 — Webpack hết heap trong cgroup build

### Hiện tượng đã xác nhận

- `update-omniroute --preflight` đã xanh, typecheck và kiểm tra i18n đều xanh.
- Webpack thoát mã 1 tại bước `Creating an optimized production build`.
- Cgroup build đạt đỉnh 8 GiB nhưng không bị kernel OOM hoặc cgroup kill.
- Production không dùng swap và vẫn hoạt động; updater không thay runtime khi
  candidate build thất bại.

### Cách xử lý

- Nâng riêng Node heap của candidate build từ 7168 lên 8192 MB.
- Lần thử đầu giữ `MemoryHigh=8G` trong khi Node heap đã là 8192 MB. Phần
  native/cache đẩy tổng RSS lên khoảng 8,8 GiB, khiến kernel giữ webpack tại
  `mem_cgroup_handle_over_high`; build chạy 39 phút nhưng chỉ dùng 14 phút CPU.
- Cấu hình sửa lại là `MemoryHigh=9G`, `MemoryMax=10G`,
  `MemorySwapMax=512M`, `CPUQuota=300%` và `CIRCLE_NODE_TOTAL=1`. Khoảng 1 GiB
  giữa ngưỡng mềm và trần cứng giữ đủ overhead mà vẫn bảo vệ host.
- Không build thủ công để thử lại. Sự cố tiếp theo ngày 2026-07-18 xác nhận
  ngay cả cgroup 10–11 GiB vẫn không phù hợp với Tiny; mọi build production đã
  được chuyển sang GitHub-hosted runner như mục bên dưới.

## 2026-07-18 — Updater build kéo dài và lần thử 11 GiB bị hủy do memory PSI

### Hiện tượng đã xác nhận

- Lần build trong cgroup 10 GiB chạy kéo dài, dùng gần trần bộ nhớ và tạo staging
  nhiều GiB. Caller bên ngoài đã hết thời gian nhưng transient systemd unit vẫn
  tiếp tục, nên tải không dừng cùng phiên gọi.
- Unit được dừng trước candidate smoke, backup, package swap hoặc restart
  production. Không có thay đổi runtime production.
- Sau khi được phép thử đúng một lần với `MemoryHigh=10G`, `MemoryMax=11G`, Node
  heap 8192 MB, giám sát phát hiện memory PSI full avg10 tăng ngay trong `npm ci`
  và chủ động hủy. Không có kernel OOM, service loss hoặc package swap.
- Không thử lần hai, không tăng lên 12 GiB và không reboot host.

### Khắc phục bắt buộc

- Wrapper giữ lock, theo dõi PID/unit, bắt INT/TERM/HUP và kill toàn control group
  để caller chết không để lại updater/candidate mồ côi.
- `npm ci`, npm install và Next production build bị loại khỏi Tiny updater.
- Exact target + ordered immutable patch snapshots được build đúng một lần trên
  GitHub-hosted `ubuntu-24.04` từ một deployment-only branch bất biến. Trước khi
  tạo request, requestor so exact target với installed `dependencyFingerprint`:
  khớp chọn `overlay`/`omniroute-runtime-overlay`, lệch chọn `full-package`/
  `omniroute-full-package`. Mode, type, policy và package/lock identities nằm trong
  canonical request; builder/updater không được silently đổi lane. GitHub attest
  chính SHA-256 của response archive.
- Overlay builder trả whitelist runtime roots. Full-package builder tạo package
  độc lập và production-pruned `node_modules` trên hosted runner, materialize
  workspace closure, validate lockfile/production/optional/native closure và loại
  dev residue. Dev `npm ci`, production prune, lifecycle/native repair và
  Turbopack đều không được chuyển về Tiny.
- Tiny chỉ xác minh fail-closed GitHub attestation cho đúng repository/workflow/
  ref/deployment SHA và hosted runner, rồi kiểm target/patch/response/manifest
  pins, exact mode/type/policy, request, platform/ABI, dependency fingerprint,
  package/lock, production-tree, native/file/link indexes và mọi file hash. Tar
  link luôn bị cấm; `.bin` link chỉ được dựng sau regular-file extraction từ
  canonical link index khi relative target nằm trong tree và trỏ vào file đã
  verify.
- Updater enforce đúng selection rule trước mutation: overlay chỉ khi deps khớp;
  full-package chỉ khi deps lệch và phải stage trực tiếp từ verified independent
  package, không copy installed package hay stale `node_modules`. Sau đó cả hai
  lane mới smoke bằng fake secrets/data, backup, atomic swap, health-check và
  rollback.
- Builder unavailable, artifact thiếu/sai, wrong lane, dependency/tree/native/link
  mismatch hoặc attestation lỗi là terminal failure. Tuyệt đối không fallback
  sang local `npm ci`, npm install, lifecycle/postinstall, native rebuild, webpack
  hoặc Turbopack.

### Chuỗi deploy mới

```text
--check
→ lightweight pinned --preflight
→ --build-artifact trên GitHub-hosted ubuntu-24.04
→ duyệt response/manifest SHA-256 + deployment ref/SHA + run ID/attempt
→ artifact-aware pinned --preflight
→ artifact-aware pinned --update
→ --verify-runtime
→ người dùng test bản đã deploy
```

Không push/open/update PR trước deploy và người dùng test nếu chưa có quyền riêng.

## 2026-07-20 — Chuỗi pin thủ công gây vòng lặp build/deploy

### Hiện tượng đã xác nhận

- Một deploy yêu cầu người vận hành truyền lại target, patch-set, artifact,
  manifest, ref, source SHA, run ID và attempt qua nhiều lệnh riêng.
- Mỗi request tạo một nhánh `deploy/artifact/*`; các lần lỗi để lại nhiều nhánh,
  worktree và staging khó kiểm soát.
- Release head có thể tiến lên trong lúc GitHub build, khiến người vận hành tưởng
  phải build lại dù artifact vẫn là ancestor mới và còn trong cửa sổ an toàn.
- npm cache đã có nhưng `.build/next/cache` chưa được giữ; candidate đúng cùng identity
  cũng không được tự tái sử dụng.

### Khắc phục bắt buộc

- Luồng thường chỉ dùng `update-omniroute --check` và
  `update-omniroute --update`.
- `--update` tự khóa target/patch-set, build hoặc reuse candidate, lấy pin từ
  `state/candidate.json`, preflight, deploy và verify; không nhập pin thủ công.
- Dùng một nhánh fast-forward cố định `deploy/integration`; commit SHA và
  attestation vẫn là provenance bất biến.
- Cache cả npm và cache build Next.js `.build/next/cache` trên GitHub-hosted runner.
- Release head đổi trong lúc build phải đi qua bounded-ancestor gate sẵn có,
  không tự khởi động lại build.
- Caller timeout hoặc mất SSH phải đọc lại request trên `deploy/integration`,
  so sánh semantic identity và tiếp tục đúng commit/run; timestamp/nonce mới
  không được tạo build trùng.
- Tiny vẫn tuyệt đối không chạy `npm ci`, production build, lifecycle hoặc native
  rebuild. Attestation, archive validation, candidate smoke, backup, atomic swap
  và rollback vẫn là cổng bắt buộc.

## 2026-07-21 — Turbopack làm cạn RAM GitHub-hosted runner

### Hiện tượng đã xác nhận

- Telemetry của run `29764024181` ghi nhận tiến trình Node/Turbopack tăng tới
  `15,090,716 KiB` RSS trên runner 15 GiB; toàn bộ 3 GiB swap cũng bị dùng hết.
- `--max-old-space-size=6144` không giới hạn được phần bộ nhớ Rust/native nằm
  ngoài V8. Runner gửi SIGTERM, builder thoát 143 và không tạo artifact.
- Production không bị chạm vì updater dừng đúng fail-closed boundary.

### Khắc phục bắt buộc

- Lane artifact GitHub dùng `OMNIROUTE_USE_TURBOPACK=0` để chọn Webpack, đúng
  fallback bộ nhớ thấp đã được mã nguồn OmniRoute hỗ trợ.
- Manifest và verifier phải khóa `buildBundler=webpack`; không được âm thầm nhận
  artifact từ bundler khác.
- Resume integration phải so byte builder, verifier và workflow hiện tại; request
  ứng dụng giống nhau nhưng toolchain khác thì phải tạo commit mới.
- Giữ heap Webpack ở 6 GiB, telemetry mỗi phút, cache `.build/next/cache` và mọi
  cổng attestation/provenance/smoke/rollback hiện có.

### Lỗi production-prune phát hiện sau khi Webpack xanh

- Webpack hoàn tất nhưng `npm ci --omit=dev` trong package-stage vấp ERESOLVE
  giữa `marked-terminal@7.3.0` và `marked@18.x`.
- Lockfile upstream được tạo với `legacy-peer-deps=true` trong `.npmrc`; package-stage
  không mang cấu hình đó nên npm dùng resolver khác với lúc tạo lockfile.
- Production-prune phải truyền rõ `--legacy-peer-deps` cùng `--ignore-scripts`.
  Không copy `.npmrc` để tránh đưa registry/auth config tương lai vào payload.
- Dùng riêng `actions/cache/restore` và `actions/cache/save`; builder chỉ
  materialize cache ngoài sau khi Next.js build xanh, nên lỗi đóng gói phía sau
  không làm mất kết quả compile.

### Upstream target đỏ sẵn ở typecheck

- Target `470e0811f` lỗi `typecheck:core` trong `src/lib/db/core.ts` và
  `agentBridgeState.ts`; hai patch local không chạm các file này.
- Hosted builder chạy cùng `typecheck:core` trên exact target nguyên bản và cây
  đã áp patch, chuẩn hóa/sắp xếp diagnostics rồi dùng phép tập hợp để phát hiện
  lỗi mới. Candidate chỉ được qua khi không thêm diagnostic so với target.

### Tên native binary của wreq-js thay đổi

- `wreq-js@2.3.1` đóng gói Linux glibc dưới tên
  `rust/wreq-js.linux-x64-gnu.node`; builder cũ chỉ tìm
  `wreq-js.linux-x64.node` nên báo thiếu dù package đã cài đúng.
- Builder chọn tên GNU hiện tại trước, giữ fallback tên cũ, chép nguyên basename
  vào package/standalone và vẫn bắt buộc `dlopen` thành công.

### Full-package kéo test của package con vào production payload

- Run `29783424308` đã hoàn tất Webpack, typecheck, production-prune, native
  validation và LLMLingua closure nhưng dừng ở artifact policy vì
  `@omniroute/opencode-plugin/tests/features.test.ts` bị chép vào package-stage.
- Nguyên nhân là builder copy nguyên thư mục `@omniroute`; cách này bỏ qua
  `package.json.files` của từng package con và kéo cả test/source dev vào payload.
- Builder phải copy `package.json` cùng đúng các entry runtime được khai báo trong
  `files`, sau đó prune test/dev residue ở các runtime root ngoài `node_modules`.
  Artifact policy vẫn giữ fail-closed; tuyệt đối không cho phép test chỉ để build qua.
- Fixture bắt buộc phải chứng minh plugin còn `dist/index.js` và metadata, đồng thời
  `@omniroute/*/tests/**`, `src/**/__tests__/**` và `open-sse/**/__tests__/**`
  không xuất hiện trong full-package.
- Run kế tiếp `29785947448` vượt qua lỗi test nhưng phát hiện
  `dist/node_modules/@asamuzakjp/css-color` là dev-only theo source lock. Đây là
  cây dependency Next standalone chép từ dev install, trùng với `node_modules`
  production-pruned ở package root. Full-package phải bỏ toàn bộ cây trùng này;
  Node resolve dependency từ `dist/server.js` lên production root. Fixture phải
  xác nhận cả việc không còn `dist/node_modules` lẫn khả năng resolve runtime đó.
