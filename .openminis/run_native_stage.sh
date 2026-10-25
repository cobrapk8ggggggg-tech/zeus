#!/usr/bin/env bash
set -euo pipefail

stage="$1"
kind="$2"
device="$3"
mkdir -p results
case "$stage" in
  boot)
    xcrun simctl boot "$device" || true
    xcrun simctl bootstatus "$device" -b
    xcrun simctl uninstall "$device" com.openminis.app || true
    ;;
  screens)
    python3 browser/.openminis/capture_reference.py "$device" \
      "$RUNNER_TEMP/OpenMinisOriginal/Build/Products/Debug-iphonesimulator/Minis.app" \
      "results/embedded-screens-$kind" --bundle tools.rea.ZEUSBrowserAnalysis
    ;;
  chat|tests|personalization)
    python3 browser/.zeus-ci/fixture_server.py > "results/fixture-server-$kind-$stage.log" 2>&1 &
    fixture_pid=$!
    finish_fixture() {
      local stage_exit=$?
      kill "$fixture_pid" 2>/dev/null || true
      if [ "$stage_exit" -ne 0 ]; then
        xcrun simctl terminate "$device" tools.rea.ZEUSBrowserAnalysis || true
        python3 browser/.openminis/collect_simulator_logs.py "$device" "results/embedded-$kind-system.log" || true
      fi
    }
    trap finish_fixture EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    for attempt in {1..30}; do
      if curl --fail --silent http://127.0.0.1:8765/v1/models > /dev/null; then break; fi
      sleep 1
    done
    curl --fail --silent http://127.0.0.1:8765/v1/models > "results/fixture-models-$kind-$stage.json"
    if [ "$stage" = chat ]; then
      python3 -u browser/.openminis/capture_chat.py "$device" tools.rea.ZEUSBrowserAnalysis \
        "results/embedded-conversation-$kind"
    elif [ "$stage" = personalization ]; then
      python3 browser/.openminis/run_xcode.py "results/embedded-$kind-ui.log" -- \
        xcodebuild -project upstream/src/ios/Minis.xcodeproj -scheme Minis \
        -configuration Debug -destination "platform=iOS Simulator,id=$device" \
        -derivedDataPath "$RUNNER_TEMP/OpenMinisOriginal" \
        -resultBundlePath "results/embedded-$kind-ui.xcresult" \
        -only-testing:ZEUSPersonalizationUITests -parallel-testing-enabled NO \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
        -maximum-test-execution-time-allowance 120 \
        test-without-building CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    else
      python3 browser/.openminis/run_xcode.py "results/embedded-$kind-tests.log" -- \
        xcodebuild -project upstream/src/ios/Minis.xcodeproj -scheme Minis \
        -configuration Debug -destination "platform=iOS Simulator,id=$device" \
        -derivedDataPath "$RUNNER_TEMP/OpenMinisOriginal" \
        -resultBundlePath "results/embedded-$kind.xcresult" \
        -only-testing:ZEUSBrowserIntegrationTests \
        -parallel-testing-enabled NO -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 90 -maximum-test-execution-time-allowance 90 \
        test-without-building CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    fi
    ;;
  attachments)
    xcrun xcresulttool export attachments --path "results/embedded-$kind.xcresult" \
      --output-path "results/embedded-attachments-$kind" || true
    if [ -d "results/embedded-$kind-ui.xcresult" ]; then
      xcrun xcresulttool export attachments --path "results/embedded-$kind-ui.xcresult" \
        --output-path "results/embedded-ui-attachments-$kind" || true
    fi
    xcrun simctl shutdown "$device" || true
    ;;
  *) exit 2 ;;
esac
