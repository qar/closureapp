#!/bin/zsh
# Xcode Cloud runs this before xcodebuild. It stamps the build number with Xcode
# Cloud's own counter, because App Store Connect refuses an upload whose build number
# was used before.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${CI_BUILD_NUMBER:-}" ]]; then
  [[ "$CI_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "错误：CI_BUILD_NUMBER 必须是整数" >&2; exit 1; }
  xcrun agvtool -noscm new-version "$CI_BUILD_NUMBER"
  echo "ci_pre_xcodebuild: build number ${CI_BUILD_NUMBER}"
else
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER is not set, build number unchanged"
fi
