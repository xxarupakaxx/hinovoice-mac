# HinoVoice for Mac — build / bundle / sign / install / verify
#
# 署名の同一性（designated requirement, 以下 DR）は Team ID で固定する。
# リーフ証明書の Common Name や有効期限に依存させないことで、証明書を
# 更新してもアクセシビリティ許可が外れないようにする（設計書 6.2）。
# Team ID は秘密情報ではない。

APP_NAME    := HinoVoice
BUNDLE_ID   := com.xxarupakaxx.hinovoice-mac
# codesign -d --verbose=4 の TeamIdentifier から読み取った値。証明書の名前に
# 括弧で入っている文字列とは別物なので、名前から推測してはいけない。
TEAM_ID     := 9HADDY47LK

BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
BIN         := .build/release/$(APP_NAME)
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

# 期待する DR。codesign -d -r- が表示する文字列と完全一致させる。
EXPECTED_DR := designated => identifier "$(BUNDLE_ID)" and anchor apple generic and certificate leaf[subject.OU] = "$(TEAM_ID)"

# 署名 ID は環境のキーチェーンにある Apple Development 証明書から引く。証明書の
# Common Name（メールアドレスを含む）をリポジトリへ書かないため、名前は指定しない。
# 証明書の名前に括弧で入っている文字列は Team ID とは別物なので、名前からの
# 絞り込みにも使わない。複数ある環境では SIGN_ID を明示して渡す。
# Team ID が合っているかどうかは、署名後に make verify が照合する。
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/ { print $$2; exit }')
SIGN_ID_COUNT := $(shell security find-identity -v -p codesigning | grep -c 'Apple Development:')

# 件数による制限は自動選択のときだけ掛ける。SIGN_ID を明示した環境では、どの
# 証明書で署名したかは利用者が決めている。合っているかどうかは make verify が
# 署名結果の Team ID で照合する。`?=` のあとに origin を見ると、未指定の場合は
# file、コマンドラインや環境から渡した場合はそれぞれの出所になる。
ifeq ($(origin SIGN_ID),file)
  REQUIRE_SINGLE_IDENTITY := 1
else
  REQUIRE_SINGLE_IDENTITY := 0
endif

TEST_WAV ?= $(HOME)/hinovoice-work/test-ja.wav

.PHONY: all build bundle sign install verify selftest clean

all: install verify

build:
	swift build -c release --arch arm64

bundle: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp THIRD-PARTY-NOTICES.md LICENSE "$(APP_BUNDLE)/Contents/Resources/"
	printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"

# Hardened Runtime（-o runtime）、サンドボックス、get-task-allow はいずれも
# 付けない（設計書 7.3）。--identifier を明示するのは、SwiftPM が作った
# バイナリからの識別子推論に頼らないためである（設計書 6.3）。
sign: bundle
	@test -n "$(SIGN_ID)" || { echo "FAIL: Apple Development 証明書が見つかりません"; exit 1; }
	@test "$(REQUIRE_SINGLE_IDENTITY)" = "0" || test "$(SIGN_ID_COUNT)" = "1" || { \
	  echo "FAIL: Apple Development 証明書が $(SIGN_ID_COUNT) 件あります。SIGN_ID='<証明書の名前>' を指定してください"; \
	  exit 1; }
	codesign --force --sign "$(SIGN_ID)" \
	  --identifier "$(BUNDLE_ID)" \
	  --requirements '=$(EXPECTED_DR)' \
	  --timestamp=none \
	  "$(APP_BUNDLE)"

install: sign
	mkdir -p "$(INSTALL_DIR)"
	rsync -a --delete "$(APP_BUNDLE)/" "$(INSTALLED)/"
	@echo "installed: $(INSTALLED)"

verify:
	@mkdir -p $(BUILD_DIR)
	@echo "--- codesign --verify --strict ---"
	codesign --verify --strict --verbose=2 "$(INSTALLED)"
	@echo "--- codesign -d --verbose=4 (TeamIdentifier) ---"
	@codesign -d --verbose=4 "$(INSTALLED)" 2>&1 | grep -E '^(Identifier|TeamIdentifier|CodeDirectory|Signature)'
	@echo "--- designated requirement ---"
	@codesign -d -r- "$(INSTALLED)" 2>/dev/null | tr '\n' ' ' \
	  | sed -e 's/.*designated =>/designated =>/' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/ *$$//' \
	  > $(BUILD_DIR)/.dr.actual
	@cat $(BUILD_DIR)/.dr.actual && echo
	@if [ "$$(cat $(BUILD_DIR)/.dr.actual)" = '$(EXPECTED_DR)' ]; then \
	  echo "OK: DR は Team ID $(TEAM_ID) で固定されている"; \
	else \
	  echo "FAIL: DR が期待値と一致しない"; \
	  echo '  expected: $(EXPECTED_DR)'; \
	  echo "  actual  : $$(cat $(BUILD_DIR)/.dr.actual)"; \
	  exit 1; \
	fi

# 人の操作を必要としない確認。マイクもアクセシビリティも使わない。
selftest: build
	@echo "--- キーの飲み込み判定（純粋関数） ---"
	"$(BIN)" --selftest-keys
	@echo "--- セッションの世代（Esc と認識完了の競合） ---"
	"$(BIN)" --selftest-session
	@echo "--- 貼り付け先の照合（入力先を確かめられないときは貼らない） ---"
	"$(BIN)" --selftest-target
	@echo "--- 終了処理の順番（開始と貼り付けの禁止、復元待ち） ---"
	"$(BIN)" --selftest-shutdown
	@echo "--- クリップボードの保存と復元 ---"
	"$(BIN)" --selftest-clipboard
	@echo "--- 16kHz モノラル 16bit への変換 ---"
	"$(BIN)" --selftest-audio "$(TEST_WAV)" "$(BUILD_DIR)/selftest-16k.wav"
	afinfo "$(BUILD_DIR)/selftest-16k.wav" | grep -E 'Data format|Channels|Sample Rate|estimated duration' || true
	@echo "--- ステレオのミックスダウン ---"
	"$(BIN)" --selftest-downmix
	@echo "--- プレビューの stable prefix（純粋関数） ---"
	"$(BIN)" --selftest-prefix
	@echo "--- プレビューの間隔とバックプレッシャー ---"
	"$(BIN)" --selftest-preview-schedule
	@echo "--- プレビューの表示状態（隠したあとに開き直さない） ---"
	"$(BIN)" --selftest-preview-window
	@echo "--- プレビューの位置（AX 座標の変換と画面への寄せ） ---"
	"$(BIN)" --selftest-preview-place
	@echo "--- 偽 worker との往復（プレビューが最終を壊さない） ---"
	"$(BIN)" --selftest-preview-worker
	@echo "--- speech worker との往復 ---"
	"$(BIN)" --selftest-worker "$(TEST_WAV)"

clean:
	rm -rf .build "$(BUILD_DIR)"
