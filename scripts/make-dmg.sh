#!/bin/bash
#
# 配布用にアーカイブ・書き出しし、「アプリケーション」フォルダへのリンク付き DMG を作る。
# 成果物は build/dist/（gitignore）に出る。
#
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/make-dmg.sh                       # Developer ID で書き出し
#   NOTARY_PROFILE=notary DEVELOPMENT_TEAM=... ./scripts/make-dmg.sh        # さらに公証して staple する
#   SIGNING=development DEVELOPMENT_TEAM=... ./scripts/make-dmg.sh          # Apple Development 署名のまま（検証用）
#
# NOTARY_PROFILE は事前に次で作っておく:
#   xcrun notarytool store-credentials notary --apple-id <Apple ID> --team-id <Team ID>
#
# Developer ID 署名には有料の Apple Developer Program と、Account Holder / Admin 権限が要る
# （-allowProvisioningUpdates でクラウド管理の Developer ID 証明書を使う）。
#
# App Group ID は $(DEVELOPMENT_TEAM) から組み立てるので、配布版は手元の開発用ビルドと
# App Group が異なることがある（選んでいたバス停は引き継がれない）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/EdoBusWidget.xcodeproj"
SCHEME="EdoBusWidget"
APP_NAME="EdoBusWidget.app"
BUNDLE_ID="jp.shigeya.EdoBusWidget"
VOLNAME="江戸バス接近情報"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${DEVELOPMENT_TEAM:-}" ]] \
  || die "DEVELOPMENT_TEAM=<Team ID> を指定してください（Developer ID を使える有料チーム）。"
TEAM="$DEVELOPMENT_TEAM"

SIGNING="${SIGNING:-developer-id}"
case "$SIGNING" in
  developer-id|development) ;;
  *) die "SIGNING は developer-id か development を指定してください: $SIGNING" ;;
esac

command -v xcodegen >/dev/null || die "xcodegen がありません（brew install xcodegen）。"
echo "==> xcodegen generate"
(cd "$REPO_ROOT" && xcodegen generate >/dev/null)

DIST="$REPO_ROOT/build/dist"
ARCHIVE="$DIST/EdoBusWidget.xcarchive"
EXPORT_DIR="$DIST/export"
STAGING="$DIST/dmg-root"

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGING"
mkdir -p "$DIST"

echo "==> アーカイブ"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="$TEAM" >"$DIST/archive.log" 2>&1 \
  || die "アーカイブに失敗しました。$DIST/archive.log を確認してください。"

ARCHIVED_APP="$ARCHIVE/Products/Applications/$APP_NAME"
[[ -d "$ARCHIVED_APP" ]] || die "アーカイブに $APP_NAME がありません。"

if [[ "$SIGNING" == "developer-id" ]]; then
  echo "==> Developer ID で書き出し"
  OPTIONS="$DIST/ExportOptions.plist"
  cat >"$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates >"$DIST/export.log" 2>&1 \
    || die "Developer ID での書き出しに失敗しました。$DIST/export.log を確認してください。
       （Developer Program の有料チームと Account Holder / Admin 権限が必要です。
        検証用なら SIGNING=development で作れます）"
else
  echo "==> Apple Development 署名のまま使う（他の Mac では Gatekeeper に止められます）"
  mkdir -p "$EXPORT_DIR"
  ditto "$ARCHIVED_APP" "$EXPORT_DIR/$APP_NAME"
fi
APP="$EXPORT_DIR/$APP_NAME"
[[ -d "$APP" ]] || die "書き出した $APP_NAME が見つかりません。"

echo "==> 署名の確認"
codesign --verify --deep --strict "$APP" || die "署名の検証に失敗しました。"
APPEX="$APP/Contents/PlugIns/EdoBusWidgetExtension.appex"
TEAM_LINE=$(codesign -dv "$APPEX" 2>&1 | grep TeamIdentifier || true)
AUTH_LINE=$(codesign -dvv "$APP" 2>&1 | grep -m1 '^Authority=' || true)
echo "    ${AUTH_LINE:-Authority が読めません}"
echo "    ${TEAM_LINE:-TeamIdentifier が読めません}"
[[ "$TEAM_LINE" != *"not set"* ]] || die "拡張が無署名です。ウィジェットは動きません。"
[[ -d "$APP/Contents/Resources/Metadata.appintents" || -n "$(find "$APP" -name Metadata.appintents -maxdepth 6)" ]] \
  || die "Metadata.appintents がありません。ウィジェットの設定パネルが動きません。"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
SUFFIX=""
[[ "$SIGNING" == "development" ]] && SUFFIX="-dev"
DMG="$DIST/EdoBusWidget-$VERSION$SUFFIX.dmg"

echo "==> DMG を作成: $DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov "$DMG" >/dev/null 2> >(grep -v deprecated >&2)
rm -rf "$STAGING"

# 手元に Developer ID Application 証明書があれば DMG にも署名する（クラウド署名だけなら省略）
DMG_IDENTITY=$(security find-identity -v -p codesigning \
  | sed -n "s/.*\"\(Developer ID Application: [^\"]*($TEAM)\)\".*/\1/p" | head -1)
if [[ "$SIGNING" == "developer-id" && -n "$DMG_IDENTITY" ]]; then
  echo "==> DMG に署名: $DMG_IDENTITY"
  codesign --sign "$DMG_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ "$SIGNING" == "developer-id" ]] || die "公証は Developer ID 署名でのみ行えます。"
  echo "==> 公証（数分かかります）"
  # notarytool は Invalid でも 0 で終わるので、status を見て判断する。
  SUBMIT_OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) \
    || { echo "$SUBMIT_OUT" >&2; die "公証の送信に失敗しました。"; }
  echo "$SUBMIT_OUT" | grep -E '^\s*(id|status):' | sort -u
  SUBMIT_ID=$(echo "$SUBMIT_OUT" | sed -n 's/^ *id: *//p' | head -1)
  if ! echo "$SUBMIT_OUT" | grep -qE '^\s*status: Accepted'; then
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "公証が通りませんでした（id: $SUBMIT_ID）。上のログを確認してください。"
  fi
  echo "==> staple"
  xcrun stapler staple "$DMG"
  MNT=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | tail -1 | cut -f3)
  spctl -a -t exec -vv "$MNT/$APP_NAME" || true
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
elif [[ "$SIGNING" == "developer-id" ]]; then
  echo "    公証していません。配布前に NOTARY_PROFILE=<profile> を付けて実行してください。"
fi

# アーカイブ・書き出し・DMG のマウントで同じ bundle ID のコピーが Launch Services に
# 登録される。残すと配置済みアプリのウィジェットが拡張を引けなくなることがあるので、
# 配置済みのもの以外を外して、配置済みのものを登録し直す。
echo "==> Launch Services から作業用コピーの登録を外す"
KEEP=()
for d in "$HOME/Applications" /Applications; do
  [[ -d "$d/$APP_NAME" ]] && KEEP+=("$d/$APP_NAME")
done
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  skip=0
  for k in ${KEEP[@]+"${KEEP[@]}"}; do [[ "$path" == "$k" ]] && skip=1; done
  (( skip )) && continue
  echo "    登録解除: $path"
  "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
done < <(
  { "$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" '
      /^-+$/ { path = "" }
      /^path:/ { sub(/^path:[[:space:]]*/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); path = $0 }
      /^identifier:/ && $2 == id && path != "" { print path; path = "" }'
    mdfind "kMDItemCFBundleIdentifier == \"$BUNDLE_ID\"" 2>/dev/null || true
  } | sort -u
)
for k in ${KEEP[@]+"${KEEP[@]}"}; do "$LSREGISTER" -f -R -trusted "$k"; done

echo "==> 完了: $DMG ($VERSION build $BUILD)"
shasum -a 256 "$DMG"
