#!/bin/bash
# 编译并打包 AIStatus.app。用法：./build.sh [--install | --dist]
#   --install  复制到 ~/Applications 并启动
#   --dist     编成 Intel 和 Apple 芯片通用的版本，打包成 build/AIStatus-<版本>.dmg，用来发给别人
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AIStatus.app"
if [ "${1:-}" = "--dist" ]; then
  swift build -c release --arch arm64 --arch x86_64
else
  swift build -c release
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AIStatus "$APP/Contents/MacOS/AIStatus"
cp Resources/Info.plist "$APP/Contents/Info.plist"

rm -rf build/AppIcon.iconset
.build/release/AIStatus --make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "✅ 已生成 $APP"

if [ "${1:-}" = "--dist" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  DMG="build/AIStatus-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/首次打开必读.txt" <<'TXT'
AI 余量：在状态栏显示 Claude Code 和 Codex 的剩余额度

安装
1. 把 AIStatus 拖到 Applications 文件夹
2. 双击打开。系统会提示「无法验证开发者」，点「完成」
3. 打开「系统设置 › 隐私与安全性」，拉到下面，点「仍要打开」，输入开机密码
   （或者在终端运行：xattr -dr com.apple.quarantine /Applications/AIStatus.app）
4. 之后它就出现在屏幕右上角的状态栏里，点图标查看额度

要求
- macOS 14 或更新
- 本机用 Claude Code 登录过 Claude 账号，或用 ChatGPT 账号登录过 Codex（用哪家显示哪家）
- 设置里可以打开「开机自动启动」
TXT
  hdiutil create -volname "AI 余量" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "✅ 已生成 ${DMG}（$(lipo -archs "$APP/Contents/MacOS/AIStatus")）"
fi

if [ "${1:-}" = "--install" ]; then
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
