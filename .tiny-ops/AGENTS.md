# Quy tắc làm việc với OmniRoute trên Tiny

Agent phải đọc toàn bộ file này và `/opt/omniroute/ops/INCIDENTS.md` trước khi
kiểm tra, cập nhật, sửa mã nguồn, test, deploy hoặc tạo PR cho OmniRoute trên
máy `tiny-server`.

## Phạm vi và kiến trúc

- OmniRoute được cài native bằng gói npm và chạy bằng `omniroute.service`; không dùng Docker.
- Runtime production không đọc mã từ checkout source hoặc worktree vá.
- Dashboard và API công khai qua Cloudflare Tunnel tại `https://api.nguyenthanhha.com`.
- Tunnel hiện có trỏ hostname trên vào `http://127.0.0.1:20130`, riêng path `/live-ws` vào `http://127.0.0.1:20132`; không tạo proxy bằng CloudPanel hoặc Nginx.
- API bridge nội bộ ở `127.0.0.1:20131/v1` và live WebSocket ở `127.0.0.1:20132`.
- Không công khai trực tiếp các cổng `20130`, `20131`, `20132` ra Internet.

## Bố cục thư mục

```text
/opt/omniroute/
  AGENTS.md              quy tắc local này; không thuộc source upstream
  config/                env và mật khẩu ban đầu, chỉ root được đọc
  data/                  dữ liệu SQLite production
  home/                  HOME của tài khoản dịch vụ omniroute
  source/                checkout chuẩn của fork; luôn giữ sạch
    .claude/worktrees/   một worktree độc lập cho mỗi bản vá
  patches/               snapshot patch gắn với PR
  staging/               candidate và cây kiểm thử tạm
  backups/               snapshot trước update
  state/                 lịch sử deploy và metadata patch
  ops/                   script vận hành local
```

Repository:

- Fork: `https://github.com/nguyenha935/OmniRoute`
- Upstream: `https://github.com/diegosouzapw/OmniRoute`

## Kiểm tra và cập nhật production

```bash
update-omniroute --check
update-omniroute --update
update-omniroute --verify-runtime
systemctl status omniroute
journalctl -u omniroute -f
```

Quy tắc bắt buộc:

1. Chạy `update-omniroute --check` trước mọi update.
2. `--check` là thao tác chỉ đọc: không fetch, checkout, stash, restart hoặc thay đổi dữ liệu.
3. Mã thoát của `--check`: `0` là khỏe và mới nhất, `10` là có bản mới, `20` là có blocker.
4. `--update` là lệnh tự động duy nhất: tự khóa target/patch-set từ `--check`, dry-run patch, build hoặc tái sử dụng candidate, đọc toàn bộ pin từ `state/candidate.json`, chạy artifact-aware preflight, deploy và `--verify-runtime`. Không nhập pin thủ công trong luồng thường.
5. Candidate luôn được publish nối tiếp trên một nhánh cố định `deploy/integration`; không tạo một nhánh tạm cho mỗi lần build. Mỗi GitHub commit vẫn là danh tính bất biến của request và artifact.
6. Workflow phải cache npm và cache build Next.js thực tế ở `.build/next/cache` (không phải `.next/cache`), nhưng cache không được thay cổng typecheck/test/build. Candidate chỉ được tái sử dụng khi target, ordered patch identity, lane, runtime, dependency fingerprint và byte nội dung builder/verifier/workflow đều khớp. Lane GitHub phải dùng Webpack có giới hạn bộ nhớ; Turbopack đã được đo đạt 15,1 GiB RSS cộng 3 GiB swap và làm chết hosted runner.
7. Nếu release head tiến lên trong lúc build, orchestration tự dùng bounded-ancestor gate có exact current-head và thời hạn tối đa 60 phút; không được bắt đầu lại build chỉ vì cùng release branch vừa có commit mới.
8. Nếu caller/SSH bị ngắt, lần `--update` sau phải resume đúng request/commit/run đã publish trên `deploy/integration` khi semantic identity khớp; không tạo build trùng chỉ vì timestamp hoặc nonce khác.
9. Kênh update mặc định là `release`: ưu tiên nhánh `release/v*` cao nhất của upstream; chỉ dùng npm stable khi không có nhánh release hoặc khi đặt rõ `OMNIROUTE_UPDATE_CHANNEL=stable`. Tuyệt đối không hạ phiên bản source-release xuống npm stable cũ hơn.
10. Khi có patch local, `--preflight` phải dry-run patch trên target đã pin; builder phải dùng đúng ordered snapshots, bỏ qua patch đã có upstream, apply patch còn lại và dừng nếu conflict.
11. Source candidate chỉ build một lần trên GitHub-hosted `ubuntu-24.04`; workflow không chạy coverage và không dùng `npm pack`. Lane full-package phải production-prune, materialize workspace closure và validate native/runtime closure hoàn toàn trên hosted runner; Tiny không được chạy lifecycle/postinstall hay native rebuild. Tiny vẫn phải xác minh GitHub attestation, exact commit/ref/run, mode/type/policy, target/patch, package/lock, platform/ABI, dependency, production-tree, native/file/link indexes và mọi payload hash trước candidate smoke.
12. Production-prune phải dùng `npm ci --omit=dev --ignore-scripts --legacy-peer-deps` vì lockfile upstream được tạo dưới `legacy-peer-deps=true`; không copy nguyên `.npmrc` vào payload và không được chạy lifecycle script.
13. Nếu exact upstream target đỏ sẵn ở `typecheck:core`, hosted builder phải chạy cùng gate trên target nguyên bản và candidate, chuẩn hóa diagnostics và chỉ cho qua khi candidate không thêm lỗi TypeScript mới. Không được bỏ typecheck hoặc dùng lỗi nền để che regression của patch.
14. `--update` phải backup package, data và config; package được đổi nguyên tử; health check lỗi hoặc tiến trình bị ngắt sau khi package thay đổi phải rollback.
15. Không chạy `npm install -g omniroute` thủ công để bỏ qua luồng update an toàn.
16. Không dùng `git stash` trong bất kỳ luồng OmniRoute nào.

## Luồng bản vá và PR

Không sửa trực tiếp `/opt/omniroute/source`. Mỗi thay đổi phải nằm trong worktree riêng:

```bash
omniroute-patch status
omniroute-patch new fix/ten-ban-va
cd /opt/omniroute/source/.claude/worktrees/fix-ten-ban-va
# đọc toàn bộ file liên quan, sửa, chạy test mục tiêu an toàn và commit
omniroute-patch snapshot fix/ten-ban-va
omniroute-patch pr fix/ten-ban-va
```

Quy tắc bắt buộc:

1. Trước khi sửa code phải xin phép người dùng và đọc đầy đủ file liên quan, `CONTRIBUTING.md`, AGENTS.md của upstream cùng tài liệu chuyên đề được upstream chỉ dẫn.
2. Code mới phải theo pattern gốc; không đổi kiến trúc gốc để hợp với code mới.
3. Với giao diện, kiểm tra CSS cascade từ thấp đến cao trước khi thêm hoặc sửa class.
4. Tên branch dùng một trong: `feat/`, `fix/`, `refactor/`, `docs/`, `test/`, `chore/`.
5. `omniroute-patch new` tự chọn nhánh `release/v*` đang hoạt động cao nhất; chỉ fallback về `main` nếu upstream không có nhánh release. Không tự tạo hoặc giả định có nhánh `dev`.
6. Mỗi PR chỉ chứa thay đổi cần gửi upstream; không đưa cấu hình Tiny, tunnel, secret hay script vận hành cá nhân vào PR.
7. Trên Tiny chỉ chạy lint đúng file thay đổi và test mục tiêu tuần tự theo mục
   "An toàn tài nguyên và test trên Tiny" bên dưới. Không chạy
   `omniroute-patch test` trên Tiny.
8. Dọn dead code và khoảng trắng thừa; giữ code ngắn gọn, rõ ràng, bảo mật và nhất quán với upstream.
9. Commit sạch rồi mới chạy `omniroute-patch pr`; lệnh tạo draft PR và lưu snapshot patch.
10. `omniroute-patch snapshot` phải xuất đúng delta từ base commit đến HEAD, lưu SHA-256 và commit vào metadata; dirty worktree là blocker.
11. Thêm `changelog.d` theo đúng số PR và quy tắc upstream trước khi chuyển PR sang ready.
12. Sync branch/fork/GitHub theo luồng của script; không đưa code worktree vào runtime production để thử trực tiếp.
13. `omniroute-patch pr` tạo draft PR. Các job nặng của upstream bỏ qua draft;
    vì vậy trạng thái draft không được xem là CI xanh và không được dùng để báo
    PR hoàn tất.
14. Khi người dùng đã cho phép đưa PR sang ready và metadata/changelog đầy đủ,
    chuyển PR sang ready để GitHub chạy các required checks. Full unit suite,
    coverage, Vitest, build và các gate liên quan phải chạy trên GitHub-hosted
    runner hoặc dedicated runner của upstream, không chạy lại trên Tiny.
15. Phải theo dõi CI đến trạng thái kết thúc. Chỉ được báo PR hoàn tất/sẵn sàng
    merge khi `gh pr checks <PR> --repo diegosouzapw/OmniRoute --required` trả
    mã 0 và không còn check required ở trạng thái pending, fail hoặc cancel.
    Check fail thì điều tra và sửa đúng lỗi; check pending thì tiếp tục chờ;
    không báo xanh dựa trên test local.

## An toàn tài nguyên và test trên Tiny

`omniroute-patch test <branch>` hiện chạy toàn bộ lint, unit test, Vitest,
coverage và production build. Luồng này có hơn 15.000 test, tự cài dependency
nếu worktree chưa có `node_modules`, tiêu thụ tài nguyên rất lớn và đã làm Tiny
nghẽn vào ngày 2026-07-17. **Cấm chạy lệnh này trên Tiny**, trừ khi người dùng
cho phép rõ ràng sau khi đã thiết kế lại nó có giới hạn tài nguyên.

Quy trình test bắt buộc trên Tiny:

1. Xác định đúng các test bao phủ những file và luồng vừa sửa; không chạy toàn
   bộ suite để kiểm tra một bản vá cục bộ.
2. Chạy tuần tự, một worker, không chạy song song với build/update hoặc test của
   worktree khác.
3. Với Node test runner, dùng mẫu đã xác nhận an toàn:

   ```bash
   DISABLE_SQLITE_AUTO_BACKUP=true node --max-old-space-size=1536 \
     --import tsx/esm \
     --import ./open-sse/utils/setupPolyfill.ts \
     --import ./tests/_setup/isolateDataDir.ts \
     --test --test-concurrency=1 \
     tests/unit/<test-muc-tieu>.test.ts
   ```

4. Với lint, chỉ truyền danh sách file thay đổi. Nếu gặp cảnh báo tồn tại sẵn,
   phải chứng minh nó có trước bản vá; không tắt rule mới trên toàn dự án.
5. Không chạy coverage, full Vitest, full unit suite hoặc `npm run build` thủ
   công trên Tiny trong pha test bản vá. Full suite là cổng CI/PR hoặc phải chạy
   trên môi trường riêng đủ tài nguyên.
6. Không tự chạy `npm ci` trong worktree mới. Nếu thiếu dependency, dừng trước
   thao tác cài đặt, kiểm tra RAM/disk và xin phép vì nó có thể cài hàng nghìn
   package.
7. Sau test, kiểm tra không còn tiến trình `node --test`, Vitest, coverage hoặc
   `next build`; dọn `coverage`, `.build`, `.env` và `node_modules` chỉ khi chắc
   chắn chúng vừa được sinh cho test và không còn cần dùng.
8. Ghi lại chính xác lệnh test, số test pass/fail và commit đã kiểm tra trong
   metadata hoặc báo cáo bản vá.

Quy trình deploy bản vá trên Tiny:

1. Worktree phải sạch, commit đầy đủ và snapshot phải khớp HEAD.
2. Chạy `update-omniroute --check`; mã 20 là blocker, mã 10 cho phép tiếp tục.
3. Chạy đúng một lệnh `update-omniroute --update`. Orchestrator tự thực hiện toàn bộ pin/preflight/build-or-reuse/attestation/smoke/backup/swap/verify; không chạy lại từng bước thủ công.
4. Thiếu/sai snapshot, artifact, provenance, lane hoặc digest là terminal failure; tuyệt đối không fallback sang `npm ci`, npm install, lifecycle/postinstall, native rebuild, webpack hay Turbopack trên Tiny.
5. Updater phải reject wrong lane trước mutation, smoke-test candidate bằng secret/data giả, backup rồi swap nguyên tử; health-check lỗi phải rollback.
6. Sau deploy kiểm tra dashboard/API, service, log và các dịch vụ khác trên Tiny bị ảnh hưởng bởi tải. Không reboot host và không sửa ứng dụng khác để che lỗi của OmniRoute.

## Cổng kiểm tra trước khi báo cáo

Không được báo "xong", "đã sửa", "đã deploy", "PR sẵn sàng" hoặc tương đương
chỉ vì đã viết code hay vì một lệnh đơn lẻ đã pass. Báo cáo phải dựa trên đúng
cổng của giai đoạn đang làm:

1. **Bản vá local:** lint đúng file thay đổi và toàn bộ test mục tiêu liên quan
   đều pass; worktree sạch; commit và snapshot khớp nhau.
2. **Deploy Tiny:** `--check` không có blocker, `--preflight` xanh với đúng pin,
   `--update` thành công và `--verify-runtime` xanh. Endpoint/service liên quan
   phải hoạt động sau deploy.
3. **PR upstream:** PR phải ở trạng thái ready và toàn bộ required checks trên
   GitHub phải kết thúc màu xanh. Draft, skipped do draft, pending hoặc test
   local không thay thế được required CI.
4. Nếu một cổng chưa xanh, chỉ báo trạng thái đang chạy hoặc blocker cụ thể;
   không dùng từ ngữ khiến người dùng hiểu rằng công việc đã hoàn tất.

Lệnh kiểm tra PR chuẩn:

```bash
gh pr checks <PR> --repo diegosouzapw/OmniRoute --required
gh pr checks <PR> --repo diegosouzapw/OmniRoute --required --watch --interval 10
```

`gh pr checks` trả mã `8` khi còn pending. Chỉ mã `0` sau khi mọi required
check kết thúc thành công mới được xem là xanh.

## Điều kiện dọn bản vá

Chỉ được xóa worktree/metadata của bản vá khi đồng thời đủ bốn điều kiện:

1. GitHub xác nhận PR đã merge.
2. Worktree sạch.
3. Snapshot patch đã được lưu.
4. Nội dung PR đã có trong stable tag đang được cài.

Nếu thiếu bất kỳ điều kiện nào thì giữ nguyên và báo rõ blocker; không tự xóa, stash hoặc ép reset.

## Cấu hình public và secret

- File runtime: `/opt/omniroute/config/omniroute.env`, mode `600`.
- Giữ `BASE_URL=http://127.0.0.1:20130` cho gọi nội bộ.
- Public URL dùng `NEXT_PUBLIC_BASE_URL` và `OMNIROUTE_PUBLIC_BASE_URL` với HTTPS.
- Live dashboard dùng `NEXT_PUBLIC_LIVE_WS_PUBLIC_URL=wss://api.nguyenthanhha.com/live-ws`; rule theo path này phải đứng trước rule hostname chung.
- `AUTH_COOKIE_SECURE=true` khi chạy qua domain HTTPS.
- Chỉ thêm origin công khai chính xác vào `LIVE_WS_ALLOWED_ORIGINS`.
- Không in, commit hoặc chép `JWT_SECRET`, `API_KEY_SECRET`, mật khẩu và tunnel credential vào log/tài liệu.
- Trước khi sửa `/etc/cloudflared/config.yml`, đọc toàn bộ file; đặt ingress hostname trước catch-all và chạy `cloudflared tunnel ingress validate` trước restart.

## Tài liệu vận hành

Đọc tiếp `/opt/omniroute/ops/README.md` để xem lệnh nhanh và cơ chế update/rollback hiện tại.
