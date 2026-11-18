#!/usr/bin/env bash
# Starts a git flow release: creates release/<version> from develop, sets the version
# in project.yml (build number back to 1), regenerates the Xcode project and commits.
# Pushes nothing. Finishing the release (merge into main, tag v<version>, merge back
# into develop) is done by hand.
#
# Usage: make release VERSION=0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: release-start.sh <version>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "错误：版本号格式应为 1.2.3" >&2; exit 1; }

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "develop" ]] || { echo "错误：请从 develop 开始发布，当前分支为 $branch" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "错误：请先提交或暂存工作区改动" >&2; exit 1; }
git show-ref --verify --quiet "refs/heads/release/$version" && { echo "错误：release/$version 已存在" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "错误：请先安装 XcodeGen" >&2; exit 1; }
command -v ruby >/dev/null || { echo "错误：找不到 Ruby" >&2; exit 1; }

git checkout -b "release/$version"
ruby -rpsych - "$version" <<'RUBY'
def value_for(mapping, key)
  abort "Expected a YAML mapping for #{key}" unless mapping.is_a?(Psych::Nodes::Mapping)
  pair = mapping.children.each_slice(2).find { |name, _| name.value == key }
  abort "Missing YAML setting: #{key}" unless pair
  pair.last
end

path = "project.yml"
base = value_for(value_for(Psych.parse_file(path).root, "settings"), "base")
lines = File.readlines(path)
{ "MARKETING_VERSION" => ARGV.fetch(0), "CURRENT_PROJECT_VERSION" => "1" }.each do |key, value|
  node = value_for(base, key)
  abort "Expected a single-line scalar for #{key}" unless node.is_a?(Psych::Nodes::Scalar) && node.start_line == node.end_line
  # Use the parsed scalar's position to preserve the spec's comments and layout.
  lines.fetch(node.start_line)[node.start_column...node.end_column] = value
end
File.write(path, lines.join)
RUBY
xcodegen generate
git add project.yml Closure.xcodeproj
git commit -m "chore: release $version"

echo
echo "已创建 release/${version}，版本为 ${version}。下一步运行 make check。"
echo "检查通过并确认后，可运行 git push -u origin release/${version}。"
