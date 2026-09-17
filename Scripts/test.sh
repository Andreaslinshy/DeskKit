#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
check_dir="${TMPDIR:-/tmp}/deskkit-checks"
mkdir -p "$check_dir"
xcrun swiftc -swift-version 5 -module-cache-path "$check_dir/modules" "$project_dir/Shared/Models.swift" "$project_dir/DeskKit/SystemSampler.swift" "$project_dir/DeskKit/ProcessServices.swift" "$project_dir/DeskKit/DataProviders.swift" "$project_dir/Tests/main.swift" -o "$check_dir/DeskKitChecks"
"$check_dir/DeskKitChecks" "$project_dir"
