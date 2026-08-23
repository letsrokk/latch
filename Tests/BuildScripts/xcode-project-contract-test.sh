#!/bin/zsh
set -euo pipefail

project="$PWD/LATCH.xcodeproj"
[[ -d "$project" ]]

listing="$(mktemp)"
project_json="$(mktemp)"
debug_settings="$(mktemp)"
release_settings="$(mktemp)"
trap 'rm -f "$listing" "$project_json" "$debug_settings" "$release_settings"' EXIT
xcodebuild -project "$project" -list -json > "$listing"
xcodebuild -project "$project" -alltargets -configuration Debug -showBuildSettings -json > "$debug_settings"
xcodebuild -project "$project" -alltargets -configuration Release -showBuildSettings -json > "$release_settings"
plutil -convert json -o "$project_json" "$project/project.pbxproj"

ruby -rjson -rrexml/document -e '
  expected_targets = %w[LATCH LATCHAgent LATCHDaemon LATCHNative LATCHProbe LATCHShared LATCHTests]
  project = JSON.parse(File.read(ARGV.fetch(0))).fetch("project")
  abort "wrong targets: #{project.fetch("targets").sort.inspect}" unless project.fetch("targets").sort == expected_targets
  abort "LATCH scheme missing" unless project.fetch("schemes").include?("LATCH")

  objects = JSON.parse(File.read(ARGV.fetch(1))).fetch("objects")
  targets = objects.map do |id, object|
    next unless object.fetch("isa") == "PBXNativeTarget"
    [object.fetch("name"), { id: id, object: object }]
  end.compact.to_h
  abort "wrong native target objects: #{targets.keys.sort.inspect}" unless targets.keys.sort == expected_targets

  expected_types = {
    "LATCH" => "com.apple.product-type.application",
    "LATCHDaemon" => "com.apple.product-type.tool",
    "LATCHAgent" => "com.apple.product-type.tool",
    "LATCHProbe" => "com.apple.product-type.tool",
    "LATCHShared" => "com.apple.product-type.library.static",
    "LATCHNative" => "com.apple.product-type.library.static",
    "LATCHTests" => "com.apple.product-type.bundle.unit-test",
  }
  expected_groups = {
    "LATCH" => "Sources/LATCHApp",
    "LATCHDaemon" => "Sources/LATCHDaemon",
    "LATCHAgent" => "Sources/LATCHAgent",
    "LATCHProbe" => "Sources/LATCHProbe",
    "LATCHShared" => "Sources/LATCHShared",
    "LATCHNative" => "Sources/LATCHNative",
    "LATCHTests" => "Tests/LATCHTests",
  }
  expected_links = {
    "LATCH" => ["LATCHShared"],
    "LATCHDaemon" => %w[LATCHNative LATCHShared],
    "LATCHAgent" => ["LATCHShared"],
    "LATCHProbe" => %w[LATCHNative LATCHShared],
    "LATCHShared" => [],
    "LATCHNative" => [],
    "LATCHTests" => ["LATCHShared"],
  }
  expected_dependencies = expected_links.merge(
    "LATCH" => %w[LATCHAgent LATCHDaemon LATCHProbe LATCHShared],
  )

  target_names_by_id = targets.to_h { |name, target| [target.fetch(:id), name] }
  target_names_by_product = targets.to_h do |name, target|
    [target.fetch(:object).fetch("productReference"), name]
  end

  synchronized_paths = objects.map do |_id, object|
    next unless object.fetch("isa") == "PBXFileSystemSynchronizedRootGroup"
    object.fetch("path")
  end.compact
  abort "wrong synchronized groups: #{synchronized_paths.sort.inspect}" unless synchronized_paths.sort == expected_groups.values.sort

  targets.each do |name, target|
    object = target.fetch(:object)
    actual_type = object.fetch("productType")
    expected_type = expected_types.fetch(name)
    abort "#{name} product type: expected #{expected_type.inspect}, got #{actual_type.inspect}" unless actual_type == expected_type

    group_paths = object.fetch("fileSystemSynchronizedGroups").map do |id|
      group_object = objects[id] or abort "#{name} references missing synchronized group #{id}"
      abort "#{name} group #{id} is not synchronized" unless group_object.fetch("isa") == "PBXFileSystemSynchronizedRootGroup"
      group_object.fetch("path")
    end
    expected_path = expected_groups.fetch(name)
    abort "#{name} synchronized groups: expected #{[expected_path].inspect}, got #{group_paths.inspect}" unless group_paths == [expected_path]

    framework_phase_ids = object.fetch("buildPhases").select do |id|
      phase = objects[id] or abort "#{name} references missing build phase #{id}"
      phase.fetch("isa") == "PBXFrameworksBuildPhase"
    end
    abort "#{name} framework phase count: expected 1, got #{framework_phase_ids.length}" unless framework_phase_ids.length == 1
    linked_targets = objects.fetch(framework_phase_ids.fetch(0)).fetch("files").map do |id|
      build_file = objects[id] or abort "#{name} Frameworks references missing build file #{id}"
      product_ref = build_file.fetch("fileRef")
      target_names_by_product[product_ref] or abort "#{name} links non-target product #{product_ref}"
    end.sort
    abort "#{name} static-library links: expected #{expected_links.fetch(name).inspect}, got #{linked_targets.inspect}" unless linked_targets == expected_links.fetch(name)

    dependencies = object.fetch("dependencies").map do |id|
      dependency = objects[id] or abort "#{name} references missing dependency #{id}"
      dependency_target = dependency.fetch("target")
      dependency_name = target_names_by_id[dependency_target] or abort "#{name} dependency #{id} points outside the project"
      proxy = objects[dependency.fetch("targetProxy")] or abort "#{name} dependency #{id} references a missing proxy"
      proxy_target = proxy.fetch("remoteGlobalIDString")
      abort "#{name} dependency #{id} proxy points to #{proxy_target}, expected #{dependency_target}" unless proxy_target == dependency_target
      abort "#{name} dependency #{id} proxy names #{proxy.fetch("remoteInfo").inspect}, expected #{dependency_name.inspect}" unless proxy.fetch("remoteInfo") == dependency_name
      dependency_name
    end.sort
    expected_target_dependencies = expected_dependencies.fetch(name)
    abort "#{name} dependencies: expected #{expected_target_dependencies.inspect}, got #{dependencies.inspect}" unless dependencies == expected_target_dependencies
  end

  configurations = {
    "Debug" => JSON.parse(File.read(ARGV.fetch(2))),
    "Release" => JSON.parse(File.read(ARGV.fetch(3))),
  }
  settings = configurations.transform_values do |entries|
    entries.group_by { |entry| entry.fetch("target") }
  end
  assert_setting = lambda do |configuration, target, name, expected|
    entries = settings.fetch(configuration).fetch(target) { abort "#{configuration} settings missing target #{target}" }
    values = entries.map { |entry| entry.fetch("buildSettings")[name] }.uniq
    abort "#{configuration} #{target} #{name}: expected #{expected.inspect}, got #{values.inspect}" unless values == [expected]
  end

  configurations.each_key do |configuration|
    actual_targets = settings.fetch(configuration).keys.sort
    abort "#{configuration} settings targets: expected #{expected_targets.inspect}, got #{actual_targets.inspect}" unless actual_targets == expected_targets

    expected_targets.each do |target|
      assert_setting.call(configuration, target, "MACOSX_DEPLOYMENT_TARGET", "15.0")
      assert_setting.call(configuration, target, "DEVELOPMENT_TEAM", "DR8RRE2NCU")
      assert_setting.call(configuration, target, "ENABLE_HARDENED_RUNTIME", "YES")
      assert_setting.call(configuration, target, "PRODUCT_NAME", target)
      assert_setting.call(configuration, target, "PRODUCT_TYPE", expected_types.fetch(target))
    end
    %w[LATCH LATCHAgent LATCHDaemon LATCHProbe LATCHShared LATCHTests].each do |target|
      assert_setting.call(configuration, target, "SWIFT_VERSION", "6.0")
    end

    {
      "LATCH" => "com.github.letsrokk.latch",
      "LATCHDaemon" => "com.github.letsrokk.latch.daemon",
      "LATCHAgent" => "com.github.letsrokk.latch.agent",
      "LATCHProbe" => "com.github.letsrokk.latch.probe",
    }.each do |target, identifier|
      assert_setting.call(configuration, target, "PRODUCT_BUNDLE_IDENTIFIER", identifier)
    end

    assert_setting.call(configuration, "LATCH", "PRODUCT_NAME", "LATCH")
    assert_setting.call(configuration, "LATCH", "CODE_SIGN_STYLE", "Automatic")
    assert_setting.call(configuration, "LATCH", "ENABLE_APP_SANDBOX", "NO")
    assert_setting.call(configuration, "LATCH", "INFOPLIST_FILE", "Packaging/App-Info.plist")
    assert_setting.call(configuration, "LATCH", "GENERATE_INFOPLIST_FILE", "NO")
    assert_setting.call(configuration, "LATCH", "ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon")

    native_include = File.join(Dir.pwd, "Sources/LATCHNative/include")
    %w[LATCHDaemon LATCHNative LATCHProbe].each do |target|
      header_values = settings.fetch(configuration).fetch(target).map do |entry|
        entry.fetch("buildSettings").fetch("HEADER_SEARCH_PATHS").split
      end.uniq
      unless header_values.all? { |paths| paths.count(native_include) == 1 }
        abort "#{configuration} #{target} HEADER_SEARCH_PATHS must contain #{native_include.inspect} exactly once, got #{header_values.inspect}"
      end
    end
    assert_setting.call(configuration, "LATCHNative", "CLANG_ENABLE_MODULES", "YES")
    assert_setting.call(configuration, "LATCHNative", "PUBLIC_HEADERS_FOLDER_PATH", "include/LATCHNative")
    assert_setting.call(configuration, "LATCHNative", "MODULEMAP_FILE", File.join(native_include, "module.modulemap"))
    assert_setting.call(configuration, "LATCHNative", "DEFINES_MODULE", "YES")
  end

  scheme = REXML::Document.new(File.read(ARGV.fetch(4)))
  assert_scheme_reference = lambda do |reference, expected_name, context|
    abort "#{context} missing BuildableReference" unless reference
    actual_name = reference.attributes["BlueprintName"]
    abort "#{context} target: expected #{expected_name.inspect}, got #{actual_name.inspect}" unless actual_name == expected_name
    expected_id = targets.fetch(expected_name).fetch(:id)
    actual_id = reference.attributes["BlueprintIdentifier"]
    abort "#{context} target ID: expected #{expected_id}, got #{actual_id.inspect}" unless actual_id == expected_id
    expected_product = objects.fetch(targets.fetch(expected_name).fetch(:object).fetch("productReference")).fetch("path")
    actual_product = reference.attributes["BuildableName"]
    abort "#{context} product: expected #{expected_product.inspect}, got #{actual_product.inspect}" unless actual_product == expected_product
    abort "#{context} has wrong container" unless reference.attributes["ReferencedContainer"] == "container:LATCH.xcodeproj"
    abort "#{context} has wrong buildable identifier" unless reference.attributes["BuildableIdentifier"] == "primary"
  end

  build_action = REXML::XPath.first(scheme, "/Scheme/BuildAction") or abort "LATCH scheme missing BuildAction"
  abort "LATCH BuildAction must use implicit dependencies" unless build_action.attributes["buildImplicitDependencies"] == "YES"
  build_entries = REXML::XPath.match(build_action, "BuildActionEntries/BuildActionEntry")
  expected_build_names = %w[LATCHShared LATCHNative LATCHDaemon LATCHAgent LATCHProbe LATCH]
  abort "LATCH scheme build entry count: expected #{expected_build_names.length}, got #{build_entries.length}" unless build_entries.length == expected_build_names.length
  build_names = build_entries.each_with_index.map do |entry, index|
    reference = REXML::XPath.first(entry, "BuildableReference")
    expected_name = expected_build_names.fetch(index)
    assert_scheme_reference.call(reference, expected_name, "LATCH scheme build entry #{index + 1}")
    %w[buildForTesting buildForRunning buildForProfiling buildForArchiving buildForAnalyzing].each do |attribute|
      abort "LATCH scheme #{expected_name} #{attribute} must be YES" unless entry.attributes[attribute] == "YES"
    end
    reference.attributes["BlueprintName"]
  end
  abort "LATCH scheme build order: expected #{expected_build_names.inspect}, got #{build_names.inspect}" unless build_names == expected_build_names

  test_action = REXML::XPath.first(scheme, "/Scheme/TestAction") or abort "LATCH scheme missing TestAction"
  abort "LATCH TestAction must use Debug" unless test_action.attributes["buildConfiguration"] == "Debug"
  testables = REXML::XPath.match(test_action, "Testables/TestableReference")
  test_names = testables.map do |testable|
    abort "LATCHTests must not be skipped" unless testable.attributes["skipped"] == "NO"
    reference = REXML::XPath.first(testable, "BuildableReference")
    assert_scheme_reference.call(reference, "LATCHTests", "LATCH scheme test entry")
    reference.attributes["BlueprintName"]
  end
  abort "LATCH scheme tests: expected [\"LATCHTests\"], got #{test_names.inspect}" unless test_names == ["LATCHTests"]

  launch_action = REXML::XPath.first(scheme, "/Scheme/LaunchAction") or abort "LATCH scheme missing LaunchAction"
  abort "LATCH LaunchAction must use Debug" unless launch_action.attributes["buildConfiguration"] == "Debug"
  launch_reference = REXML::XPath.first(launch_action, "BuildableProductRunnable/BuildableReference")
  assert_scheme_reference.call(launch_reference, "LATCH", "LATCH scheme run action")
  launch_name = launch_reference && launch_reference.attributes["BlueprintName"]
  abort "LATCH scheme run target: expected \"LATCH\", got #{launch_name.inspect}" unless launch_name == "LATCH"

  archive_action = REXML::XPath.first(scheme, "/Scheme/ArchiveAction") or abort "LATCH scheme missing ArchiveAction"
  abort "LATCH ArchiveAction must use Release" unless archive_action.attributes["buildConfiguration"] == "Release"
' "$listing" "$project_json" "$debug_settings" "$release_settings" "$project/xcshareddata/xcschemes/LATCH.xcscheme"
