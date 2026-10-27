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
  chat|tests|personalization|cloud)
    # A forcibly timed-out prior stage can leave its server running. Never
    # accept that stale listener as the new stage's health check.
    fixture_pid_file="results/fixture-server.pid"
    if [ -f "$fixture_pid_file" ]; then
      previous_fixture_pid="$(cat "$fixture_pid_file")"
      if [[ "$previous_fixture_pid" =~ ^[0-9]+$ ]]; then
        previous_fixture_command="$(ps -p "$previous_fixture_pid" -o command= 2>/dev/null || true)"
        case "$previous_fixture_command" in
          *'.zeus-ci/fixture_server.py'*)
            kill "$previous_fixture_pid" 2>/dev/null || true
            for attempt in {1..50}; do
              if ! kill -0 "$previous_fixture_pid" 2>/dev/null; then break; fi
              sleep 0.1
            done
            previous_fixture_command="$(ps -p "$previous_fixture_pid" -o command= 2>/dev/null || true)"
            case "$previous_fixture_command" in *'.zeus-ci/fixture_server.py'*) kill -KILL "$previous_fixture_pid" 2>/dev/null || true ;; esac
            ;;
        esac
      fi
    fi
    python3 browser/.zeus-ci/fixture_server.py > "results/fixture-server-$kind-$stage.log" 2>&1 &
    fixture_pid=$!
    printf '%s\n' "$fixture_pid" > "$fixture_pid_file"
    finish_fixture() {
      local stage_exit=$?
      kill "$fixture_pid" 2>/dev/null || true
      wait "$fixture_pid" 2>/dev/null || true
      if [ -f "$fixture_pid_file" ] && [ "$(cat "$fixture_pid_file")" = "$fixture_pid" ]; then rm "$fixture_pid_file"; fi
      if [ "$stage_exit" -ne 0 ]; then
        xcrun simctl terminate "$device" tools.rea.ZEUSBrowserAnalysis || true
        python3 browser/.openminis/collect_simulator_logs.py "$device" "results/embedded-$kind-system.log" || true
      fi
    }
    trap finish_fixture EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    for attempt in {1..30}; do
      if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "results/fixture-server-$kind-$stage.log"; exit 1; fi
      if curl --fail --silent http://127.0.0.1:8765/v1/models > /dev/null; then break; fi
      sleep 1
    done
    curl --fail --silent http://127.0.0.1:8765/v1/models > "results/fixture-models-$kind-$stage.json"
    kill -0 "$fixture_pid"
    if [ "$stage" = chat ]; then
      python3 -u browser/.openminis/capture_chat.py "$device" tools.rea.ZEUSBrowserAnalysis \
        "results/embedded-conversation-$kind"
    elif [ "$stage" = cloud ]; then
      python3 browser/.openminis/run_xcode.py "results/embedded-$kind-cloud-ui.log" -- \
        xcodebuild -project upstream/src/ios/Minis.xcodeproj -scheme Minis \
        -configuration Debug -destination "platform=iOS Simulator,id=$device" \
        -derivedDataPath "$RUNNER_TEMP/OpenMinisOriginal" \
        -resultBundlePath "results/embedded-$kind-cloud-ui.xcresult" \
        -only-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudFreshChatNeverInstallsLocalLinuxOrPrewarmsAMathWebView \
        -only-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudLoginScreenRendersArabicAndRequiresCredentials \
        -only-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudPartialReplyAppearsInOriginalMessageListBeforeCompletion \
        -only-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudToolsRenderWithTheOriginalNativeCards \
        -parallel-testing-enabled NO -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60 \
        test-without-building CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
    elif [ "$stage" = personalization ]; then
      python3 browser/.openminis/run_xcode.py "results/embedded-$kind-ui.log" -- \
        xcodebuild -project upstream/src/ios/Minis.xcodeproj -scheme Minis \
        -configuration Debug -destination "platform=iOS Simulator,id=$device" \
        -derivedDataPath "$RUNNER_TEMP/OpenMinisOriginal" \
        -resultBundlePath "results/embedded-$kind-ui.xcresult" \
        -only-testing:ZEUSPersonalizationUITests -parallel-testing-enabled NO \
        -skip-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudFreshChatNeverInstallsLocalLinuxOrPrewarmsAMathWebView \
        -skip-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudLoginScreenRendersArabicAndRequiresCredentials \
        -skip-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudPartialReplyAppearsInOriginalMessageListBeforeCompletion \
        -skip-testing:ZEUSPersonalizationUITests/NativePersonalizationUITests/testCloudToolsRenderWithTheOriginalNativeCards \
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
