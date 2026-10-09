#!/bin/zsh
# Captures raw App Store screenshots into Raw/<device>/<language>/.
# Usage: ./capture.sh [languages...]   (defaults to en ja)
#        DEVICES=iPad ./capture.sh    (defaults to iPhone, iPad and Watch)
#        SHOTS=02-format,03-chart ./capture.sh   (defaults to every shot)
#
# Each run seeds the app with the presentation from samples.py, then the
# AppStoreScreenshots UI test opens it and writes the captures. Run
# compose.swift afterwards to frame them.
#
# The watch has no iPhone to follow, so the WatchScreenshotStates test renders
# what an iPhone would send it from the same presentation, and the watch app
# is launched with each state. Its captures go straight to Watch/<language>/,
# since the store takes them as they are.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
BUNDLE_ID=com.tsubuzaki.Dazzle
WATCH_BUNDLE_ID=com.tsubuzaki.Dazzle.watchkitapp
DERIVED_DATA=/tmp/dazzle-screenshots-dd
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)
typeset -A DEVICE_TYPES=(
  iPhone com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max
  iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
  Watch com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-4-49mm
)
typeset -A RUNTIMES=(
  iPhone com.apple.CoreSimulator.SimRuntime.iOS-27-0
  iPad com.apple.CoreSimulator.SimRuntime.iOS-27-0
  Watch com.apple.CoreSimulator.SimRuntime.watchOS-27-0
)
# How long each watch shot has been presenting for, in seconds.
typeset -A WATCH_ELAPSED=(
  01-remote 252
  02-chart 618
)

# MARK: - Simulators

simulator() {
  local name="Dazzle Screenshots $1" udid
  udid=$(xcrun simctl list devices available | grep "$name (" | head -1 | grep -oE '[0-9A-F-]{36}' || true)
  if [[ -z $udid ]]; then
    udid=$(xcrun simctl create "$name" $DEVICE_TYPES[$1] $RUNTIMES[$1])
  fi
  echo $udid
}

# The document browser runs out of process and follows the system language, not
# the app's, so the whole simulator is switched and restarted for each language.
# The preferences are edited while it is shut down: a `defaults write` through
# simctl spawn does not survive the restart.
boot() {
  local locale=$([[ $2 == ja ]] && echo ja_JP || echo en_US)
  local preferences=~/Library/Developer/CoreSimulator/Devices/$1/data/Library/Preferences/.GlobalPreferences.plist
  # The first boot is what creates the preferences.
  xcrun simctl boot $1 2>/dev/null || true
  xcrun simctl bootstatus $1 -b >/dev/null
  xcrun simctl shutdown $1
  # Shutdown can return while the device still reports itself booted.
  while xcrun simctl list devices | grep -q "$1) (Booted)"; do sleep 1; done
  plutil -replace AppleLanguages -json "[\"$2\"]" "$preferences"
  plutil -replace AppleLocale -string $locale "$preferences"
  xcrun simctl boot $1
  xcrun simctl bootstatus $1 -b >/dev/null
  # watchOS does not take status bar overrides, so the watch shows the real time.
  [[ $3 == Watch ]] && return
  xcrun simctl status_bar $1 override --time 9:41 \
    --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""
}

# MARK: - Build

xcodebuild build-for-testing -project "$PROJECT_DIR/Dazzle.xcodeproj" -scheme Dazzle \
  -destination "generic/platform=iOS Simulator" -derivedDataPath $DERIVED_DATA -quiet
APP=$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Dazzle.app
WATCH_APP=$(ls -d $APP/Watch/*.app | head -1)
XCTESTRUN=$(ls $DERIVED_DATA/Build/Products/*.xctestrun | head -1)

# UI tests on a freshly booted simulator now and then miss a tap, so a failed run
# is given one more go. The test sets light and dark itself.
run_test() {
  run_test_once "$@" || run_test_once "$@"
}

# Prints only the assertion that failed, if any; -quiet would hide it.
run_test_once() {
  local log=$(mktemp) test_status=0
  TEST_RUNNER_SCREENSHOT_DIR=$3 TEST_RUNNER_SCREENSHOT_LANGUAGE=$2 TEST_RUNNER_SCREENSHOT_ONLY=$SHOTS \
    xcodebuild test-without-building -xctestrun $XCTESTRUN -destination "id=$1" \
    -only-testing:DazzleUITests/AppStoreScreenshots/testScreens \
    -collect-test-diagnostics never -test-timeouts-enabled YES -maximum-test-execution-time-allowance 1800 >$log 2>&1 || test_status=$?
  grep -E "error: -\[" $log || true
  rm -f $log
  return $test_status
}

# Writes the sample presentation for a language into the directory given,
# with the browser's file times matched to the 9:41 status bar.
seed() {
  local samples="$(uv run --quiet --with python-pptx python3 "$SCRIPT_DIR/samples.py" $1)"
  mkdir -p "$2"
  cp "$samples/"* "$2/"
  rm -r "$samples"
  touch -t 202610080915 "$2/"*
}

# MARK: - Watch states

# Renders each language's watch states on the iPhone simulator, before it is
# taken up by its own captures. Leaves them in $WATCH_STATES/<language>/.
watch_states() {
  local udid=$(simulator iPhone) language deck
  WATCH_STATES=$(mktemp -d)
  xcrun simctl boot $udid 2>/dev/null || true
  xcrun simctl bootstatus $udid -b >/dev/null
  for language in $LANGUAGES; do
    seed $language "$WATCH_STATES/deck-$language"
    deck=$(ls "$WATCH_STATES/deck-$language/"*.pptx | head -1)
    TEST_RUNNER_SCREENSHOT_WATCH_DIR="$WATCH_STATES/$language" TEST_RUNNER_SCREENSHOT_DECK="$deck" \
      xcodebuild test-without-building -xctestrun $XCTESTRUN -destination "id=$udid" \
      -only-testing:DazzleTests/WatchScreenshotStates -collect-test-diagnostics never -quiet >/dev/null 2>&1 \
      || { echo "could not render the watch states for $language"; return 1 }
  done
}

# Launches the watch app with each state and captures its screen.
capture_watch() {
  local udid=$(simulator Watch) language state name container
  for language in $LANGUAGES; do
    out_dir="$SCRIPT_DIR/Watch/$language"
    mkdir -p "$out_dir"
    boot $udid $language Watch

    xcrun simctl terminate $udid $WATCH_BUNDLE_ID 2>/dev/null || true
    xcrun simctl uninstall $udid $WATCH_BUNDLE_ID 2>/dev/null || true
    xcrun simctl install $udid "$WATCH_APP"
    container="$(xcrun simctl get_app_container $udid $WATCH_BUNDLE_ID data)/tmp"
    mkdir -p "$container"

    for state in "$WATCH_STATES/$language/"*.plist; do
      name=${state:t:r}
      [[ -z $SHOTS || ,$SHOTS, == *,$name,* ]] || continue
      cp "$state" "$container/state.plist"
      # The timer counts from when the talk began, so that is set just before launch.
      plutil -replace startedAt -float $(( $(date +%s) - ${WATCH_ELAPSED[$name]:-300} )) "$container/state.plist"
      xcrun simctl terminate $udid $WATCH_BUNDLE_ID 2>/dev/null || true
      SIMCTL_CHILD_DAZZLE_REMOTE_STATE="$container/state.plist" xcrun simctl launch $udid $WATCH_BUNDLE_ID >/dev/null
      # Let the app finish launching and the thumbnail come in.
      sleep 4
      xcrun simctl io $udid screenshot --type=png "$out_dir/$name.png" 2>/dev/null
    done
    echo "captured Watch/$language"
  done
}

# MARK: - Capture

# One language at a time on one device; the iPhone and iPad run side by side.
capture() {
  local device=$1 udid=$(simulator $1) language
  for language in $LANGUAGES; do
    raw_dir="$SCRIPT_DIR/Raw/$device/$language"
    mkdir -p "$raw_dir"
    boot $udid $language $device

    # A fresh install, so the browser has no recents and no document to restore.
    xcrun simctl terminate $udid $BUNDLE_ID 2>/dev/null || true
    xcrun simctl uninstall $udid $BUNDLE_ID 2>/dev/null || true
    xcrun simctl install $udid $APP

    seed $language "$(xcrun simctl get_app_container $udid $BUNDLE_ID data)/Documents"

    run_test $udid $language "$raw_dir"
    echo "captured $device/$language"
  done
}

devices=(${=DEVICES:-iPhone iPad Watch})
(( ${devices[(Ie)Watch]} )) && watch_states
pids=()
for device in $devices; do
  if [[ $device == Watch ]]; then
    capture_watch &
  else
    capture $device &
  fi
  pids+=($!)
done
# A plain `wait` would report success even when a device's run failed.
failed=0
for pid in $pids; do
  wait $pid || failed=1
done
[[ -n $WATCH_STATES ]] && rm -rf "$WATCH_STATES"
exit $failed
