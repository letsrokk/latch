#!/bin/zsh
set -euo pipefail

project="$PWD/LATCH.xcodeproj"
[[ -d "$project" ]]

debug_settings="$(mktemp)"
release_settings="$(mktemp)"
trap 'rm -f "$debug_settings" "$release_settings"' EXIT

xcodebuild -project "$project" -alltargets -configuration Debug -showBuildSettings -json > "$debug_settings"
xcodebuild -project "$project" -alltargets -configuration Release -showBuildSettings -json > "$release_settings"

ruby -rjson -e '
  expected_targets = %w[LATCH LATCHAgent LATCHDaemon LATCHNative LATCHProbe LATCHShared LATCHTests]
  target_bundle_identifiers = {
    "LATCH" => "com.github.letsrokk.latch",
    "LATCHDaemon" => "com.github.letsrokk.latch.daemon",
    "LATCHAgent" => "com.github.letsrokk.latch.agent",
    "LATCHProbe" => "com.github.letsrokk.latch.probe",
  }

  configuration_settings = {
    "Debug" => JSON.parse(File.read(ARGV.fetch(0))),
    "Release" => JSON.parse(File.read(ARGV.fetch(1))),
  }.transform_values do |entries|
    entries.group_by { |entry| entry.fetch("target") }
  end

  get_setting = lambda do |configuration, target, key|
    entries = configuration_settings.fetch(configuration).fetch(target) { abort "#{configuration} settings missing target #{target}" }
    values = entries.map { |entry| entry.fetch("buildSettings")[key] }.uniq
    abort "#{configuration} #{target} #{key}: expected single value, got #{values.inspect}" unless values.length == 1
    values.fetch(0)
  end

  configuration_settings.each do |configuration, entries|
    actual_targets = entries.keys.sort
    abort "#{configuration} settings targets: expected #{expected_targets.sort.inspect}, got #{actual_targets.inspect}" unless actual_targets == expected_targets.sort

    expected_targets.each do |target|
      abort "#{configuration} #{target} missing target" unless entries.key?(target)
      abort "#{configuration} #{target} MACOSX_DEPLOYMENT_TARGET must be 15.0" unless get_setting.call(configuration, target, "MACOSX_DEPLOYMENT_TARGET") == "15.0"
      abort "#{configuration} #{target} DEVELOPMENT_TEAM must be DR8RRE2NCU" unless get_setting.call(configuration, target, "DEVELOPMENT_TEAM") == "DR8RRE2NCU"
      abort "#{configuration} #{target} ENABLE_HARDENED_RUNTIME must be YES" unless get_setting.call(configuration, target, "ENABLE_HARDENED_RUNTIME") == "YES"
    end

    abort "LATCH Info.plist must remain Packaging/App-Info.plist" unless get_setting.call(configuration, "LATCH", "INFOPLIST_FILE") == "Packaging/App-Info.plist"
    abort "LATCH should run without app sandbox" unless get_setting.call(configuration, "LATCH", "ENABLE_APP_SANDBOX") == "NO"
    abort "LATCH must use AppIcon as the app icon catalog entry" unless get_setting.call(configuration, "LATCH", "ASSETCATALOG_COMPILER_APPICON_NAME") == "AppIcon"

    target_bundle_identifiers.each do |target, identifier|
      abort "#{configuration} #{target} PRODUCT_BUNDLE_IDENTIFIER must be #{identifier}" unless get_setting.call(configuration, target, "PRODUCT_BUNDLE_IDENTIFIER") == identifier
    end
  end
' "$debug_settings" "$release_settings"
