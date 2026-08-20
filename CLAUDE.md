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

理由: AppIntents（`SelectEdoBusStopIntent` など、ウィジェットの設定パネル）は署名に Team ID が必要で、
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
「ウィジェットを編集」から「江戸バス接近情報」を追加する必要がある（README の「ビルドと導入」参照）。

## 既知の落とし穴: ウィジェットギャラリーのアプリ一覧が英語名になる

ウィジェットギャラリー左サイドバーのアプリ一覧には `EdoBusWidget` と出る。`Info.plist` の
`CFBundleName` / `CFBundleDisplayName` を日本語にしても変わらない（設定済みだが効いていない）。
一覧が参照しているのは `.app` バンドルのファイル名（Spotlight の `kMDItemDisplayName`）である。

**この日本語化は 2026-08-14 に試みて失敗し、元に戻した。同じ手順を繰り返さないこと。**

試したこと:

- `PRODUCT_NAME` を日本語にする → `CodeSign failed`（"code object is not signed at all"）でビルドが壊れる
- `WRAPPER_NAME: 江戸バス接近情報.app` を `EdoBusWidget` ターゲットに設定 → バンドル名・`kMDItemDisplayName`・
  `pluginkit` の Display Name はすべて日本語になり、署名（Team ID）も正常。**それでもギャラリーの
  一覧は英語名のまま変わらなかった**
- `CFBundleVersion` を上げて chronod に再取り込みさせる → 変化なし。そもそも正常動作している
  他アプリのウィジェットも `1` のままなので、バージョンは関係ない
- Launch Services の古い登録（実体の無い `/private/tmp/dd*/...` が 10 件残っていた）を `lsregister -u` で掃除 → 変化なし
- chronod のキャッシュ行を削除して再取り込みさせる（後述） → **ギャラリーから項目自体が消え、
  `pluginkit` に正しく登録し直しても復活しなかった**

最後の状態が最も悪く、ウィジェットが一覧に出ず配置もできなくなる。復旧は `WRAPPER_NAME` を外して
`EdoBusWidget.app` に戻し、再ビルドして配置し直す。

再挑戦するなら、この Mac の既存の状態を触るのではなく、ウィジェットを一度も配置していない
クリーンなユーザーアカウントで検証すること。

### 調査に使えるコマンド

```sh
# バンドル名が Spotlight に反映されているか
mdls -name kMDItemDisplayName ~/Applications/EdoBusWidget.app

# ウィジェット拡張として認識されている名前
pluginkit -mAvvv -p com.apple.widgetkit-extension | grep -A6 jp.shigeya.EdoBusWidget.Widget

# Launch Services の登録一覧（実体の無いパスが残っていたら -u で解除、-f で再登録）
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -dump | grep -iE "path:.*EdoBus" | sort -u
```

### chronod のキャッシュ（触る場合は慎重に）

配置済みウィジェット 1 つにつき 1 行が
`~/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql` の `Descriptors` にあり、
BLOB（NSKeyedArchiver 形式）にアプリ名・バンドルパス・選択中のバス停が焼き付いている。
`ExtensionMetadata` にも 1 行。chronod は既存インスタンスのディスクリプタを再取得しないため、
`killall chronod` でも再ビルドでも古い値が残り続ける。

SIP が有効なため `launchctl bootout gui/$UID/com.apple.chronod` は拒否される。編集する場合は
`PRAGMA busy_timeout` でロック解放を待つ。**この行を消すと配置済みウィジェットが失われ、
ギャラリーに復活しないことがある。** 実行前に必ず `chrono.sql` / `-wal` / `-shm` を控えること。

```sh
DB=~/Library/Group\ Containers/group.com.apple.chronod/chronod/chrono.sql
sqlite3 "$DB" "select bundleIdentifier, version from ExtensionMetadata where bundleIdentifier like '%shigeya%'"
```

## ウィジェットが真っ白／更新されないとき: AppIntents の登録切れ

配置済みウィジェットが何も表示しなくなり、chronod のログに次が出る場合。

```
E EdoBusWidgetExtension [com.apple.chrono:widget]
  Error getting AppIntent from LNAction: AppIntents.PerformIntentError.intentNotFound
E chronod [com.apple.chrono:timeline.store]
  reload: failed with error CHSErrorDomain Code=1101 "Returned view collection was either nil or empty."
```

原因は AppIntents（`SelectEdoBusStopIntent` / `RefreshEdoBusIntent`）が解決できないこと。ウィジェットの
一時停止・更新ボタンが `Button(intent:)` で AppIntent を参照しているため、これが見つからないと
ビュー全体の構築が失敗し、空のビューが返って更新が止まる。バンドル内に `Metadata.appintents` が
あり、署名に Team ID が付いていても、Launch Services 側の登録が壊れると起きる
（`lsregister -u` / `-f` や `pluginkit -r` / `-a` を手で叩いた後に発生した）。

復旧は Launch Services への再帰的な再登録。`-f` 単体では直らず、`-R -trusted` が要る。

```sh
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
osascript -e 'tell application "EdoBusWidget" to quit'
pkill -f "MacOS/EdoBusWidget$"; pkill -f EdoBusWidgetExtension
$LSR -f -R -trusted ~/Applications/EdoBusWidget.app
open ~/Applications/EdoBusWidget.app
killall chronod
```

確認は chronod のログを流し、`Request ended for EdoBusWidget:... - success` が出ること。
`~/Library/Containers/jp.shigeya.EdoBusWidget.Widget/Data/SystemData/com.apple.chrono/timelines/EdoBusWidget/`
に `.chrono-timeline` が生成されていれば描画できている。

```sh
log stream --level debug --predicate 'process == "EdoBusWidgetExtension" OR process == "chronod"' --style compact
```

これで直らないときは次節（型名の衝突）を疑うこと。症状は同じでも原因が違う。

## ウィジェットが更新されない: 他プロジェクトと AppIntent の型名が衝突している

上と症状（`intentNotFound` → `CHSErrorDomain Code=1101`）はまったく同じだが原因が違うケース。
**署名も Launch Services も正常なのに直らない場合はこちら。`lsregister -R -trusted` では直らない。**

見分け方は、拡張のログに出る intent ダンプの中身を見ること。バンドルIDや mangled name が
**このプロジェクトのものでなければ**こちら。

```
EdoBusWidgetExtension[849] intent = { _extensionBundleId = "com.example.TobusWidget.Widget";
                                      BundleIdentifier = "com.example.TobusWidget"; Name = TobusWidget; }
EdoBusWidgetExtension[849] Could not find an intent with identifier SelectBusStopIntent,
                           mangledTypeName: Optional("20TobusWidgetExtension19SelectBusStopIntentV")
```

AppIntent の識別子は既定で型名になる。このプロジェクトはフォーク元の `TobusWidget`（都バス、
`~/Applications/TobusWidget.app`、バンドル `com.example.TobusWidget`）と型名が同じだったため、
`SelectBusStopIntent` / `RefreshBusIntent` / `TogglePauseIntent` が両アプリで衝突していた。その結果、
配置済みウィジェットの設定に**フォーク元側の intent 記述子が焼き付き**、ウィジェットの設定パネルにも
都バスの路線・バス停が出る状態になっていた。

再起動するまで表面化しないので注意。chronod は解決済みの設定をメモリに持っているため、
再起動でディスク上の記述子を読み直した瞬間に一斉に壊れる。

2026-08-20 に江戸バス側を `SelectEdoBusStopIntent` / `RefreshEdoBusIntent` / `ToggleEdoBusPauseIntent`
へ改名して解消した。**この系統の intent を追加するときは、必ず `EdoBus` を含む一意な型名にすること。**

なお `TobusWidget` は現役で稼働中（配置済みインスタンスあり、正常更新）。残骸ではないので削除しないこと。

復旧手順は次の3つが全部必要。どれか一つでも欠けると直らない。

1. 型名を改名して衝突を解消する
2. `CURRENT_PROJECT_VERSION` を上げてビルドし直す（次節。上げないと chronod が古い記述子を使い続ける）
3. **配置済みウィジェットを削除して、ギャラリーから追加し直す**

3 が要るのは、既に保存済みの設定を chronod が移行してくれないため。「ウィジェットを編集」では
保存済みの intent がそのまま開くだけなので直らない。削除して新規に追加すること。

## アプリを入れ替えたときは CFBundleVersion を上げる

`~/Applications/EdoBusWidget.app` を置き換えても、`CFBundleVersion` が同じままだと chronod は
「更新された拡張」と判定せず、**古いウィジェット記述子（kind と設定 intent の対応）を使い続ける**。
intent を改名したのに古い名前が要求され続ける、といった症状になる。

`project.yml` の `CURRENT_PROJECT_VERSION` を上げて（両ターゲット）再生成・再ビルド・再配置すると、
chronod が古い記述子を破棄して読み直す。

```
chronod [com.apple.chrono:placeholder] Purging placeholders for removed descriptor:
        <CHSWidgetDescriptor: kind: EdoBusWidget; ...; hasDefaultIntent: NO>
    hasDefaultIntent = YES;
```

`hasDefaultIntent` が `YES` になり、placeholder 要求が success になれば取り込み直されている。

これは「ギャラリーのアプリ一覧が英語名になる」件（版数を上げても変化なし）とは別の話で、
そちらには効かないがこちらには効く。

## ログの確認

```sh
log stream --predicate 'subsystem beginswith "jp.shigeya.EdoBusWidget"' --level debug
```

アプリ／ウィジェット拡張どちらのログもまとめて見える。`API request: <path>` がサーバーへの実リクエスト。
