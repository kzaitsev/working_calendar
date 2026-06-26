APP_NAME := WorkingCalendar
BUNDLE_ID := dev.codex.WorkingCalendar
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
SOURCES := $(shell find Sources/WorkingCalendar -name '*.swift' | sort)
PROTOCOL_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyICSProtocol
PROTOCOL_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Tools/VerifyICSProtocol.swift
CALDAV_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyCalDAVDiscovery
CALDAV_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Sources/WorkingCalendar/CalDAVDiscovery.swift Sources/WorkingCalendar/CalDAVClient.swift Tools/VerifyCalDAVDiscovery.swift
SUBSCRIPTION_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyICSSubscription
SUBSCRIPTION_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/CalendarSubscriptionDecoder.swift Sources/WorkingCalendar/CalendarSubscriptionHTTP.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Sources/WorkingCalendar/CalendarSubscriptionAnnotator.swift Tools/VerifyICSSubscription.swift
PROVIDER_BRIDGE_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyProviderICSBridges
PROVIDER_BRIDGE_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Sources/WorkingCalendar/GoogleCalendarClient.swift Sources/WorkingCalendar/MicrosoftGraphCalendarClient.swift Tools/VerifyProviderICSBridges.swift
PROVIDER_WRITE_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyProviderWritePayloads
PROVIDER_WRITE_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Sources/WorkingCalendar/CalDAVDiscovery.swift Sources/WorkingCalendar/CalDAVClient.swift Sources/WorkingCalendar/GoogleCalendarClient.swift Sources/WorkingCalendar/MicrosoftGraphCalendarClient.swift Tools/VerifyProviderWritePayloads.swift
PROVIDER_OUTBOX_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyProviderOutbox
PROVIDER_OUTBOX_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Tools/VerifyProviderOutbox.swift
OAUTH_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyOAuthDeviceFlow
OAUTH_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Tools/VerifyOAuthDeviceFlow.swift
PROVIDER_SYNC_RECOVERY_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyProviderSyncRecovery
PROVIDER_SYNC_RECOVERY_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Sources/WorkingCalendar/ProviderICSObjectSyncer.swift Sources/WorkingCalendar/CalDAVDiscovery.swift Sources/WorkingCalendar/CalDAVClient.swift Sources/WorkingCalendar/GoogleCalendarClient.swift Sources/WorkingCalendar/MicrosoftGraphCalendarClient.swift Tools/VerifyProviderSyncRecovery.swift
PROVIDER_ONBOARDING_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyProviderOnboarding
PROVIDER_ONBOARDING_VERIFY_SOURCES := Sources/WorkingCalendar/ProviderOnboardingCatalog.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/CalDAVDiscovery.swift Tools/VerifyProviderOnboarding.swift
PROVIDER_DIAGNOSTICS_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyProviderDiagnostics
PROVIDER_DIAGNOSTICS_VERIFY_SOURCES := $(filter-out Sources/WorkingCalendar/WorkingCalendarApp.swift,$(SOURCES)) Tools/VerifyProviderDiagnostics.swift
LIVE_PROVIDER_SMOKE_EXECUTABLE := $(BUILD_DIR)/LiveProviderSmoke
LIVE_PROVIDER_SMOKE_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/CalendarURLNormalizer.swift Sources/WorkingCalendar/OAuthDeviceFlowClient.swift Sources/WorkingCalendar/ProviderRetryAfter.swift Sources/WorkingCalendar/ProviderDiagnostics.swift Sources/WorkingCalendar/LiveProviderSmokeContract.swift Sources/WorkingCalendar/CalendarProviderStore.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Sources/WorkingCalendar/CalendarSubscriptionDecoder.swift Sources/WorkingCalendar/CalendarSubscriptionHTTP.swift Sources/WorkingCalendar/CalDAVDiscovery.swift Sources/WorkingCalendar/CalDAVClient.swift Sources/WorkingCalendar/GoogleCalendarClient.swift Sources/WorkingCalendar/MicrosoftGraphCalendarClient.swift Tools/LiveProviderSmoke.swift
LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyLiveProviderSmokeContract
LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_SOURCES := $(filter-out Sources/WorkingCalendar/WorkingCalendarApp.swift,$(SOURCES)) Tools/VerifyLiveProviderSmokeContract.swift
GRID_STORE_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyCalendarGridStore
GRID_STORE_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/LocalCalendarStore.swift Sources/WorkingCalendar/LocalCalendarICSCodec.swift Tools/VerifyCalendarGridStore.swift
GRID_LAYOUT_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyCalendarGridLayout
GRID_LAYOUT_VERIFY_SOURCES := $(filter-out Sources/WorkingCalendar/WorkingCalendarApp.swift,$(SOURCES)) Tools/VerifyCalendarGridLayout.swift
ALERT_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyAlertEngine
ALERT_VERIFY_SOURCES := Sources/WorkingCalendar/Models.swift Sources/WorkingCalendar/MeetingLinkExtractor.swift Sources/WorkingCalendar/AlertEngine.swift Tools/VerifyAlertEngine.swift
APP_INTEGRATION_VERIFY_EXECUTABLE := $(BUILD_DIR)/VerifyAppIntegration
APP_INTEGRATION_VERIFY_SOURCES := Sources/WorkingCalendar/ExternalCalendarOpenDeduper.swift Tools/VerifyAppIntegration.swift
ICON := Resources/AppIcon.icns
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
NO_EVENTKIT_PATTERN := [E]ventKit|[C]alendarService|[E]KEvent|[E]KEventStore|[N]SCalendars|[O]pen in Calendar|[S]ystem Calendar|[s]ystem calendar|[R]equest Calendar Access|[C]alendar permissions|[a]lready configured in macOS Calendar
NO_DIRECT_PROVIDER_BYPASS_PATTERN := Task \{ await writeBack|Task \{ await delete|enqueueCalDAVWriteBack|enqueueGoogleCalendarWriteBack|enqueueMicrosoft365WriteBack|enqueueCalDAVDelete|enqueueGoogleCalendarDelete|enqueueMicrosoft365Delete|enqueueGoogleCalendarResponse|enqueueMicrosoft365Response

.PHONY: build run verify no-eventkit no-direct-provider-bypass app-integration ics-protocol caldav-discovery ics-subscription provider-ics-bridges provider-write-payloads provider-outbox oauth-device-flow provider-sync-recovery provider-onboarding provider-diagnostics live-provider-smoke-build live-provider-smoke-contract live-provider-smoke live-provider-smoke-preflight live-provider-smoke-strict calendar-grid-store calendar-grid-layout alert-engine clean

build: $(EXECUTABLE)

verify: build no-eventkit no-direct-provider-bypass app-integration ics-protocol caldav-discovery ics-subscription provider-ics-bridges provider-write-payloads provider-outbox oauth-device-flow provider-sync-recovery provider-onboarding provider-diagnostics live-provider-smoke-build live-provider-smoke-contract calendar-grid-store calendar-grid-layout alert-engine

no-eventkit:
	@if rg -n '$(NO_EVENTKIT_PATTERN)' Sources/WorkingCalendar Resources Makefile -S; then \
		echo "Standalone invariant failed: remove native calendar framework references."; \
		exit 1; \
	else \
		echo "Standalone calendar invariant passed."; \
	fi

no-direct-provider-bypass:
	@if rg -n '$(NO_DIRECT_PROVIDER_BYPASS_PATTERN)' Sources/WorkingCalendar/AppModel.swift -S; then \
		echo "Provider outbox invariant failed: route remote mutations through provider outbox."; \
		exit 1; \
	else \
		echo "Provider outbox invariant passed."; \
	fi

app-integration: $(APP_INTEGRATION_VERIFY_EXECUTABLE)
	@"$(APP_INTEGRATION_VERIFY_EXECUTABLE)"

ics-protocol: $(PROTOCOL_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(PROTOCOL_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

caldav-discovery: $(CALDAV_VERIFY_EXECUTABLE)
	@"$(CALDAV_VERIFY_EXECUTABLE)"

ics-subscription: $(SUBSCRIPTION_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(SUBSCRIPTION_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

provider-ics-bridges: $(PROVIDER_BRIDGE_VERIFY_EXECUTABLE)
	@"$(PROVIDER_BRIDGE_VERIFY_EXECUTABLE)"

provider-write-payloads: $(PROVIDER_WRITE_VERIFY_EXECUTABLE)
	@"$(PROVIDER_WRITE_VERIFY_EXECUTABLE)"

provider-outbox: $(PROVIDER_OUTBOX_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(PROVIDER_OUTBOX_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

oauth-device-flow: $(OAUTH_VERIFY_EXECUTABLE)
	@"$(OAUTH_VERIFY_EXECUTABLE)"

provider-sync-recovery: $(PROVIDER_SYNC_RECOVERY_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(PROVIDER_SYNC_RECOVERY_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

provider-onboarding: $(PROVIDER_ONBOARDING_VERIFY_EXECUTABLE)
	@"$(PROVIDER_ONBOARDING_VERIFY_EXECUTABLE)"

provider-diagnostics: $(PROVIDER_DIAGNOSTICS_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(PROVIDER_DIAGNOSTICS_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

live-provider-smoke: $(LIVE_PROVIDER_SMOKE_EXECUTABLE)
	@"$(LIVE_PROVIDER_SMOKE_EXECUTABLE)"

live-provider-smoke-build: $(LIVE_PROVIDER_SMOKE_EXECUTABLE)
	@echo "Live provider smoke build invariant passed."

live-provider-smoke-contract: $(LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_EXECUTABLE)
	@"$(LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_EXECUTABLE)"

live-provider-smoke-preflight: $(LIVE_PROVIDER_SMOKE_EXECUTABLE)
	@WC_LIVE_PREFLIGHT=1 \
	WC_LIVE_USE_STORED_SOURCES="$${WC_LIVE_USE_STORED_SOURCES:-1}" \
	WC_LIVE_REQUIRE_SOURCES="$${WC_LIVE_REQUIRE_SOURCES:-all}" \
	WC_LIVE_REQUIRE_REFRESH_OAUTH="$${WC_LIVE_REQUIRE_REFRESH_OAUTH:-1}" \
	"$(LIVE_PROVIDER_SMOKE_EXECUTABLE)"

live-provider-smoke-strict: $(LIVE_PROVIDER_SMOKE_EXECUTABLE)
	@WC_LIVE_REQUIRE_SOURCES="$${WC_LIVE_REQUIRE_SOURCES:-all}" \
	WC_LIVE_REQUIRE_WRITE_SMOKE="$${WC_LIVE_REQUIRE_WRITE_SMOKE:-1}" \
	WC_LIVE_REQUIRE_RESPONSES="$${WC_LIVE_REQUIRE_RESPONSES:-1}" \
	WC_LIVE_REQUIRE_REFRESH_OAUTH="$${WC_LIVE_REQUIRE_REFRESH_OAUTH:-1}" \
	"$(LIVE_PROVIDER_SMOKE_EXECUTABLE)"

calendar-grid-store: $(GRID_STORE_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(GRID_STORE_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

calendar-grid-layout: $(GRID_LAYOUT_VERIFY_EXECUTABLE)
	@tmp_home=$$(mktemp -d); \
	HOME="$$tmp_home" "$(GRID_LAYOUT_VERIFY_EXECUTABLE)"; \
	status=$$?; \
	rm -rf "$$tmp_home"; \
	exit $$status

alert-engine: $(ALERT_VERIFY_EXECUTABLE)
	@"$(ALERT_VERIFY_EXECUTABLE)"

$(EXECUTABLE): $(SOURCES) Resources/Info.plist $(ICON) Makefile
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(ICON)" "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(APP_DIR)/Contents/Info.plist"
	swiftc -swift-version 5 -O -g -target arm64-apple-macos14.0 -sdk "$(SDK)" $(SOURCES) -o "$(EXECUTABLE)"

$(PROTOCOL_VERIFY_EXECUTABLE): $(PROTOCOL_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROTOCOL_VERIFY_SOURCES) -o "$(PROTOCOL_VERIFY_EXECUTABLE)"

$(CALDAV_VERIFY_EXECUTABLE): $(CALDAV_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(CALDAV_VERIFY_SOURCES) -o "$(CALDAV_VERIFY_EXECUTABLE)"

$(SUBSCRIPTION_VERIFY_EXECUTABLE): $(SUBSCRIPTION_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(SUBSCRIPTION_VERIFY_SOURCES) -o "$(SUBSCRIPTION_VERIFY_EXECUTABLE)"

$(PROVIDER_BRIDGE_VERIFY_EXECUTABLE): $(PROVIDER_BRIDGE_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROVIDER_BRIDGE_VERIFY_SOURCES) -o "$(PROVIDER_BRIDGE_VERIFY_EXECUTABLE)"

$(PROVIDER_WRITE_VERIFY_EXECUTABLE): $(PROVIDER_WRITE_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROVIDER_WRITE_VERIFY_SOURCES) -o "$(PROVIDER_WRITE_VERIFY_EXECUTABLE)"

$(PROVIDER_OUTBOX_VERIFY_EXECUTABLE): $(PROVIDER_OUTBOX_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROVIDER_OUTBOX_VERIFY_SOURCES) -o "$(PROVIDER_OUTBOX_VERIFY_EXECUTABLE)"

$(OAUTH_VERIFY_EXECUTABLE): $(OAUTH_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(OAUTH_VERIFY_SOURCES) -o "$(OAUTH_VERIFY_EXECUTABLE)"

$(PROVIDER_SYNC_RECOVERY_VERIFY_EXECUTABLE): $(PROVIDER_SYNC_RECOVERY_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROVIDER_SYNC_RECOVERY_VERIFY_SOURCES) -o "$(PROVIDER_SYNC_RECOVERY_VERIFY_EXECUTABLE)"

$(PROVIDER_ONBOARDING_VERIFY_EXECUTABLE): $(PROVIDER_ONBOARDING_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROVIDER_ONBOARDING_VERIFY_SOURCES) -o "$(PROVIDER_ONBOARDING_VERIFY_EXECUTABLE)"

$(PROVIDER_DIAGNOSTICS_VERIFY_EXECUTABLE): $(PROVIDER_DIAGNOSTICS_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(PROVIDER_DIAGNOSTICS_VERIFY_SOURCES) -o "$(PROVIDER_DIAGNOSTICS_VERIFY_EXECUTABLE)"

$(LIVE_PROVIDER_SMOKE_EXECUTABLE): $(LIVE_PROVIDER_SMOKE_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(LIVE_PROVIDER_SMOKE_SOURCES) -o "$(LIVE_PROVIDER_SMOKE_EXECUTABLE)"

$(LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_EXECUTABLE): $(LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_SOURCES) -o "$(LIVE_PROVIDER_SMOKE_CONTRACT_VERIFY_EXECUTABLE)"

$(GRID_STORE_VERIFY_EXECUTABLE): $(GRID_STORE_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(GRID_STORE_VERIFY_SOURCES) -o "$(GRID_STORE_VERIFY_EXECUTABLE)"

$(GRID_LAYOUT_VERIFY_EXECUTABLE): $(GRID_LAYOUT_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(GRID_LAYOUT_VERIFY_SOURCES) -o "$(GRID_LAYOUT_VERIFY_EXECUTABLE)"

$(ALERT_VERIFY_EXECUTABLE): $(ALERT_VERIFY_SOURCES) Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(ALERT_VERIFY_SOURCES) -o "$(ALERT_VERIFY_EXECUTABLE)"

$(APP_INTEGRATION_VERIFY_EXECUTABLE): $(APP_INTEGRATION_VERIFY_SOURCES) Resources/Info.plist Makefile
	mkdir -p "$(BUILD_DIR)"
	swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -sdk "$(SDK)" $(APP_INTEGRATION_VERIFY_SOURCES) -o "$(APP_INTEGRATION_VERIFY_EXECUTABLE)"

$(ICON): Tools/GenerateIcon.swift
	rm -rf "$(BUILD_DIR)/AppIcon.iconset"
	mkdir -p "$(BUILD_DIR)/AppIcon.iconset"
	swift Tools/GenerateIcon.swift "$(BUILD_DIR)/AppIcon.iconset"
	iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(ICON)"

run: build
	open "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"
