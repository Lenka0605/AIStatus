#!/bin/bash
# 编译并打包 AIStatus.app。用法：./build.sh [--install | --dist | --release]
#   --install  复制到 ~/Applications 并启动
#   --dist     编成 Intel 和 Apple 芯片通用的版本，打包成 build/AIStatus-<版本>.dmg，用来发给别人
#   --release  在 --dist 的基础上发布到 GitHub Releases（tag 为 v<版本>）。
#              发新版：先改 Resources/Info.plist 里的 CFBundleShortVersionString 和 CFBundleVersion，
#              再运行这个；已经装了的用户会在 6 小时内收到更新提示
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AIStatus.app"
MODE="${1:-}"
if [ "$MODE" = "--dist" ] || [ "$MODE" = "--release" ]; then
  swift build -c release --arch arm64 --arch x86_64
else
  swift build -c release
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIStatus "$APP/Contents/MacOS/AIStatus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

rm -rf build/AppIcon.iconset
.build/release/AIStatus --make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "✅ 已生成 $APP"

if [ "$MODE" = "--dist" ] || [ "$MODE" = "--release" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  DMG="build/AIStatus-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/Read Me First · 首次打开必读 · Đọc trước.txt" <<'TXT'
AI 余量 / AI Quota / Hạn mức AI
https://github.com/Lenka0605/AIStatus

━━━━━━━━━━━━━━━━ 简体中文 ━━━━━━━━━━━━━━━━
在状态栏显示 Claude Code、Codex 的剩余额度和 DeepSeek 等 API 余额

安装
1. 把 AIStatus 拖到 Applications 文件夹
2. 双击打开。系统会提示「无法验证开发者」，点「完成」
3. 打开「系统设置 › 隐私与安全性」，拉到下面，点「仍要打开」，输入开机密码
   （或者在终端运行：xattr -dr com.apple.quarantine /Applications/AIStatus.app）
4. 之后它就出现在屏幕右上角的状态栏里，点图标查看额度
以后的新版本会在应用里提示，点「更新」自动安装，不用再做第 2、3 步

要求：macOS 14 或更新；本机用 Claude Code 或 Codex 登录过（用哪家显示哪家）

━━━━━━━━━━━━━━━━ English ━━━━━━━━━━━━━━━━
Shows your remaining Claude Code and Codex quota, plus DeepSeek and other API balances, in the menu bar.

Install
1. Drag AIStatus into the Applications folder
2. Double-click it. macOS says it can't verify the developer — click "Done"
3. Open System Settings › Privacy & Security, scroll down, click "Open Anyway" and enter your password
   (or run in Terminal: xattr -dr com.apple.quarantine /Applications/AIStatus.app)
4. The icon appears in the menu bar at the top right. Click it to see your quota
Future versions are offered inside the app — click "Update" and it installs itself, no need to repeat steps 2–3

Requires macOS 14 or later, and Claude Code or Codex signed in on this Mac (whichever you use is shown)

━━━━━━━━━━━━━━━━ Tiếng Việt ━━━━━━━━━━━━━━━━
Hiển thị hạn mức còn lại của Claude Code, Codex và số dư API (DeepSeek…) trên thanh menu.

Cài đặt
1. Kéo AIStatus vào thư mục Applications
2. Nhấp đúp để mở. macOS báo không xác minh được nhà phát triển — nhấn "Xong"
3. Mở Cài đặt hệ thống › Quyền riêng tư & Bảo mật, cuộn xuống, nhấn "Vẫn mở" và nhập mật khẩu máy
   (hoặc chạy trong Terminal: xattr -dr com.apple.quarantine /Applications/AIStatus.app)
4. Biểu tượng sẽ xuất hiện trên thanh menu ở góc trên bên phải. Nhấn vào để xem hạn mức
Các phiên bản sau sẽ được thông báo ngay trong ứng dụng — nhấn "Cập nhật" để tự cài, không cần làm lại bước 2–3

Yêu cầu: macOS 14 trở lên; đã đăng nhập Claude Code hoặc Codex trên máy này
TXT
  hdiutil create -volname "AI Quota" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "✅ 已生成 ${DMG}（$(lipo -archs "$APP/Contents/MacOS/AIStatus")）"
fi

if [ "$MODE" = "--release" ]; then
  TAG="v$VERSION"
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "❌ $TAG 已经发布过了，先在 Resources/Info.plist 里把版本号改大" >&2
    exit 1
  fi
  # 固定名字的 AIStatus.dmg：README 里的下载链接 releases/latest/download/AIStatus.dmg 永远指向最新版
  cp "$DMG" build/AIStatus.dmg
  NOTES="build/release-notes.md"
  [ -f "$NOTES" ] || printf 'AIStatus %s\n\n下载 / Download / Tải về: AIStatus.dmg\n' "$VERSION" > "$NOTES"
  gh release create "$TAG" build/AIStatus.dmg "$DMG" --title "AIStatus $VERSION" --notes-file "$NOTES"
  rm -f build/AIStatus.dmg "$NOTES"
  echo "✅ 已发布 $TAG"
fi

if [ "$MODE" = "--install" ]; then
  pkill -x AIStatus 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/AIStatus.app
  # 移动而不是复制，并从 LaunchServices 注销 build/ 里的副本，避免启动台/聚焦搜索里出现两个
  mv "$APP" ~/Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PWD/$APP" 2>/dev/null || true
  open ~/Applications/AIStatus.app
  echo "✅ 已安装到 ~/Applications 并启动"
fi
