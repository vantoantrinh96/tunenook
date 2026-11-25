# Deadline khi tạo task mới — design ngắn

## Vì sao
Từ v0.10.0 deadline thuộc về task, nhưng chỉ đặt được qua sheet `TaskEditor`
(chuột phải → Edit…) sau khi task đã tạo. Hai bước, khó phát hiện. Mục tiêu: đặt
deadline ngay lúc tạo task trên `NewTaskBar`.

## Mục tiêu / không làm
- Mục tiêu: chọn deadline trong 1–2 click ngay trên thanh thêm task; thói quen gõ
  tiêu đề + Enter giữ nguyên.
- Không làm: parse ngày trong tiêu đề (cách B); đổi menu chuột phải / sheet
  `TaskEditor` (cách C); đổi model, sync, MCP.
- Anti-goal: thanh thêm task bị rối hoặc mặc định gán deadline khi người dùng không chọn.

## Các cách đã cân nhắc
- **A. Nút lịch trên thanh thêm task + popover chọn nhanh** — đã chọn: đúng chỗ
  vướng, dễ thấy, không đổi luồng gõ.
- B. Parse ngày trong tiêu đề — nhanh nhưng khó phát hiện, dễ nhận nhầm, phải lo hai ngôn ngữ.
- C. Chọn deadline nhanh trên dòng task — vẫn phải tạo trước rồi mới sửa.

## Thiết kế
```
[ Add a task…                 ] [📅] [♪ 1 ±] [Add]          ← chưa chọn
[ Add a task…                 ] [📅 Tomorrow ✕] [♪ 1 ±] [Add] ← đã chọn
```
- Nút 📅 (chỉ icon khi trống, `.help("Deadline")`) nằm giữa ô tiêu đề và stepper ♪.
- Bấm mở popover:
  - Hàng chọn nhanh: **Today**, **Tomorrow**, **Next week** (thứ Hai tuần sau).
  - Lịch `DatePicker(.graphical)`, chỉ cho chọn từ hôm nay trở đi.
  - Nút **No deadline** khi đang có ngày.
  - Chọn nhanh → đóng popover; chọn trên lịch → cập nhật ngay, popover vẫn mở để đổi lại.
- Khi đã chọn: nút thành chip "📅 Today / Tomorrow / Nov 28" (dùng cùng cách
  hiển thị ngày như `DueLabel`), có ✕ để xoá.
- Add (nút hoặc Enter) tạo `TodoTask(..., deadline:)`, rồi reset deadline về trống
  cùng lúc reset tiêu đề và ♪; focus quay lại ô tiêu đề.

## Quyết định của builder (mình chọn, có thể sửa)
- Lưu deadline là `startOfDay` của ngày chọn (`DueLabel` và trang Progress so theo ngày).
- Logic tính ngày chọn nhanh tách thành hàm thuần để viết unit test.
