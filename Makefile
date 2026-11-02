# HinoVoice for Mac — build / bundle / sign / install / verify
#
# 署名の同一性（designated requirement, 以下 DR）は Team ID で固定する。
# リーフ証明書の Common Name や有効期限に依存させないことで、証明書を
# 更新してもアクセシビリティ許可が外れないようにする（設計書 6.2）。
# Team ID は秘密情報ではない。

APP_NAME    := HinoVoice
BUNDLE_ID   := com.xxarupakaxx.hinovoice-mac
TEAM_ID     := BZHZY5UCL3

BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
BIN         := .build/release/$(APP_NAME)
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

# 期待する DR。codesign -d -r- が表示する文字列と完全一致させる。
EXPECTED_DR := designated => identifier "$(BUNDLE_ID)" and anchor apple generic and certificate leaf[subject.OU] = "$(TEAM_ID)"

# 署名 ID は環境のキーチェーンから Team ID で引く。証明書の Common Name
# （メールアドレスを含む）をリポジトリへ書かないため、ここでは解決しない。
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development:.*\($(TEAM_ID)\)/ { print $$2; exit }')

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
	@test -n "$(SIGN_ID)" || { echo "FAIL: Team ID $(TEAM_ID) の Apple Development 証明書が見つかりません"; exit 1; }
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
	  echo "  expected: $(EXPECTED_DR)"; \
	  echo "  actual  : $$(cat $(BUILD_DIR)/.dr.actual)"; \
	  exit 1; \
	fi

# 人の操作を必要としない確認。マイクもアクセシビリティも使わない。
selftest: build
	@echo "--- キーの飲み込み判定（純粋関数） ---"
	"$(BIN)" --selftest-keys
	@echo "--- クリップボードの保存と復元 ---"
	"$(BIN)" --selftest-clipboard
	@echo "--- 16kHz モノラル 16bit への変換 ---"
	"$(BIN)" --selftest-audio "$(TEST_WAV)" "$(BUILD_DIR)/selftest-16k.wav"
	afinfo "$(BUILD_DIR)/selftest-16k.wav" | grep -E 'Data format|Channels|Sample Rate|estimated duration' || true
	@echo "--- speech worker との往復 ---"
	"$(BIN)" --selftest-worker "$(TEST_WAV)"

clean:
	rm -rf .build "$(BUILD_DIR)"
