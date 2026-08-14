# 新規クローン直後のセットアップ

`EdoBusWidget.xcodeproj` / `Info.plist` / `*.entitlements` は `project.yml` から生成する
ファイルで、`.gitignore` によりリポジトリには含まれていない。クローン直後は以下が必要。

```sh
# 1. XcodeGen が未インストールなら入れる
brew install xcodegen

# 2. project.yml からXcodeプロジェクト一式を生成する
#    （Info.plist / entitlements / .xcodeproj もこの時点で作られる）
xcodegen generate
```

`xcodegen generate` を実行しないと `xcodebuild` はプロジェクトファイルが無くて失敗するので、
このリポジトリで初めてビルドするときは必ず先に行うこと。`project.yml` を編集したときも
再実行が必要（README の「構成」参照）。

ここまで終えたら、下記の「署名付きビルドコマンド」に進む。Xcode.app から GUI でビルドする場合は
`open EdoBusWidget.xcodeproj` した上で、README の「Signing & Capabilities」の手順（両ターゲットに
自分の Team を設定）に従うこと。

# ビルドについて（重要）

このプロジェクトをローカルでビルドして `~/Applications/EdoBusWidget.app` へ配置する（＝実際にウィジェットを動かして確認する）場合は、
**必ず Team ID 付きで署名すること。** `CODE_SIGNING_REQUIRED=NO` / `CODE_SIGN_IDENTITY=""` などの無署名ビルドは
コンパイルが通るかの確認にしか使わないこと。

理由: AppIntents（`SelectBusStopIntent` など、ウィジェットの設定パネル）は署名に Team ID が必要で、
無署名や Team ID なしの adhoc 署名だと `Unable to get teamId` となり、ウィジェットが情報を更新できず
プレースホルダのまま止まる。過去に無署名ビルドを誤って `~/Applications/EdoBusWidget.app` に上書きし、
この症状が発生したことがある。

## 署名付きビルドコマンド

証明書名と Team ID は環境ごとに異なる個人情報なので、このファイル（公開リポジトリに含まれる）には書かない。
まず手元の証明書を確認する。

```sh
security find-identity -v -p codesigning
```

表示された証明書名から、次のコマンドで Team ID（OU）を確認できる。

```sh
security find-certificate -c "<証明書名>" -p | openssl x509 -noout -subject
```

それらを使ってビルドする。

```sh
xcodebuild -project EdoBusWidget.xcodeproj -scheme EdoBusWidget \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="<証明書名>" \
  DEVELOPMENT_TEAM=<Team ID> \
  PROVISIONING_PROFILE_SPECIFIER="" \
  CONFIGURATION_BUILD_DIR=build \
  build
```

## 実機（ウィジェット）で確認する場合の反映手順

ビルドしただけでは配置済みのウィジェットには反映されない。実際に使っているコピーは
`~/Applications/EdoBusWidget.app` なので、確認のたびに次の手順で入れ替える。

```sh
# 1. 実行中のプロセスを終了
osascript -e 'tell application "EdoBusWidget" to quit'
pkill -f "MacOS/EdoBusWidget$"
pkill -f "EdoBusWidgetExtension"

# 2. 署名付きビルドを配置し直す
rm -rf ~/Applications/EdoBusWidget.app
cp -R build/EdoBusWidget.app ~/Applications/
open ~/Applications/EdoBusWidget.app
```

`codesign -dv ~/Applications/EdoBusWidget.app/Contents/PlugIns/EdoBusWidgetExtension.appex` の
`TeamIdentifier` が実際の Team ID になっていることを確認できる（`TeamIdentifier=not set` なら無署名ビルドが紛れ込んでいる）。

初回（まだ `~/Applications/EdoBusWidget.app` が存在しない環境）は `quit` / `pkill` は何もせず失敗するだけなので
無視してよい。また、起動しただけではウィジェットは画面に出ない。通知センターまたはデスクトップの
「ウィジェットを編集」から「江戸バス」を追加する必要がある（README の「ビルドと導入」参照）。

## ログの確認

```sh
log stream --predicate 'subsystem beginswith "jp.shigeya.EdoBusWidget"' --level debug
```

アプリ／ウィジェット拡張どちらのログもまとめて見える。`API request: <path>` がサーバーへの実リクエスト。
