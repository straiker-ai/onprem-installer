#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Three checks, run together:
#  1. charts/image-tags.yaml (source of truth for Straiker-owned image tags)
#     vs. the values.yaml files that actually declare them.
#  2. Every local (non-remote) subchart's Chart.yaml version vs. its parent's
#     declared dependency constraint.
#  3. What every chart actually renders (helm template) vs. what
#     charts/straiker-artifact/values.yaml declares it mirrors — catches
#     drift `yq`-based checks 1/2 can't, e.g. third-party images or a
#     templating bug that computes a tag differently than values.yaml states.
#
# `--fix` resolves what's fixable (check #1, cascading into the chart-version
# bumps check #2 verifies) by propagating charts/image-tags.yaml into its
# targets, then re-runs all three checks to report the resulting state.
# Check #3 has no `--fix` — it flags drift for images this script doesn't
# own the source of truth for, which needs a human decision, not a rewrite.

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is required." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required." >&2
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: perl is required." >&2
  exit 1
fi

usage() {
  echo "Usage: $(basename "$0") [--fix]" >&2
  exit 1
}

FIX=false
if [[ $# -gt 0 ]]; then
  [[ $# -eq 1 && "$1" == "--fix" ]] || usage
  FIX=true
fi

MANIFEST="charts/image-tags.yaml"
ARTIFACT_VALUES="charts/straiker-artifact/values.yaml"

# repo|valuesFile|yqPath|ownChartDir|parentChartDir (parentChartDir empty for
# standalone top-level charts). Every repo also implicitly targets
# ARTIFACT_VALUES's imageMirror.images[destRepository==repo].tag, handled
# once in the loop body below rather than duplicated per row here.
TARGETS=(
  "straiker/frontend|charts/straiker-core/charts/straiker-frontend/values.yaml|.frontend.image.tag|charts/straiker-core/charts/straiker-frontend|charts/straiker-core"
  "straiker/frontend-migrate|charts/straiker-core/charts/straiker-frontend/values.yaml|.frontend.dbMigrate.image.tag|charts/straiker-core/charts/straiker-frontend|charts/straiker-core"
  "straiker/argus|charts/straiker-defend/values.yaml|.image.tag|charts/straiker-defend|"
  "straiker/iris|charts/straiker-ascend/values.yaml|.image.tag|charts/straiker-ascend|"
  "straiker/vllm|charts/straiker-inference/values.yaml|.image.tag|charts/straiker-inference|"
)

manifest_repos() { yq -r '.images | keys | .[]' "$MANIFEST"; }
manifest_tag() { yq -r ".images[\"$1\"].tag" "$MANIFEST"; }
artifact_tag() { yq -r "(.imageMirror.images[] | select(.destRepository == \"$1\")).tag" "$ARTIFACT_VALUES"; }
chart_version() { yq -r '.version' "$1"; }                                              # $1 = Chart.yaml path
dep_version() { yq -r ".dependencies[] | select(.name == \"$2\") | .version" "$1"; }     # $1=parent Chart.yaml $2=child name

# "X.Y.Z" -> "X.Y.(Z+1)"
bump_patch() {
  local ver="$1" major minor patch
  IFS='.' read -r major minor patch <<<"$ver"
  echo "${major}.${minor}.$((patch + 1))"
}

# contains <needle> <haystack...>
contains() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

assert_written() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: failed to write ${desc} (expected '${expected}', got '${actual}')" >&2
    exit 1
  fi
}

# Targeted perl substitutions, not `yq -i`: yq fully re-parses and
# re-serializes the whole YAML document, which strips blank lines and
# collapses folded `description: >` block scalars even when only one field
# changes — unacceptable noise on hand-authored, heavily-commented
# values.yaml/Chart.yaml files. yq is still used for all *reads* (safe, no
# mutation).

# Rewrite a service chart's `tag:` field that sits at or shortly after
# (skipping comment-only lines) a `repository: <repo>` line.
write_service_tag() {
  local file="$1" repo="$2" newtag="$3"
  REPO="$repo" NEWTAG="$newtag" perl -0777 -pi -e \
    's/(repository:[ \t]*\Q$ENV{REPO}\E[ \t]*\n(?:[ \t]*#[^\n]*\n)*[ \t]*tag:[ \t]*)\S+/${1}$ENV{NEWTAG}/' \
    "$file"
}

# Rewrite charts/straiker-artifact/values.yaml's `tag:` field for the
# imageMirror.images[] entry whose `source:` line ends in "/<repo>".
write_artifact_tag() {
  local file="$1" repo="$2" newtag="$3"
  REPO="$repo" NEWTAG="$newtag" perl -0777 -pi -e \
    's/(source:[ \t]*\S*\/\Q$ENV{REPO}\E[ \t]*\n[ \t]*tag:[ \t]*)\S+/${1}$ENV{NEWTAG}/' \
    "$file"
}

# Bump a chart's own top-level `version:` field (anchored at column 0, so it
# can never match a nested, indented dependency `version:` field).
write_chart_version() {
  local chart_yaml="$1" newver="$2"
  NEWVER="$newver" perl -pi -e 's/^version:.*/version: $ENV{NEWVER}/' "$chart_yaml"
}

# Bump the version constraint for local dependency $2 in parent Chart.yaml $1.
write_dependency_version() {
  local parent_chart_yaml="$1" child_name="$2" newver="$3"
  CHILD="$child_name" NEWVER="$newver" perl -0777 -pi -e \
    's/(-\s*name:\s*\Q$ENV{CHILD}\E\s*\n\s*version:\s*")[^"]*(")/${1}$ENV{NEWVER}${2}/' \
    "$parent_chart_yaml"
}

fix_manifest_drift() {
  local changed_charts=()
  local touched_parents=()
  local bumped_pairs=() # "chartDir=newVersion"

  local repo tag a_tag row t_repo t_file t_path t_chart t_parent cur

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    tag="$(manifest_tag "$repo")"

    a_tag="$(artifact_tag "$repo")"
    if [[ "$a_tag" != "$tag" ]]; then
      write_artifact_tag "$ARTIFACT_VALUES" "$repo" "$tag"
      assert_written "${ARTIFACT_VALUES} destRepository=${repo} tag" "$(artifact_tag "$repo")" "$tag"
      contains "charts/straiker-artifact" "${changed_charts[@]:-}" || changed_charts+=("charts/straiker-artifact")
    fi

    for row in "${TARGETS[@]}"; do
      IFS='|' read -r t_repo t_file t_path t_chart t_parent <<<"$row"
      [[ "$t_repo" == "$repo" ]] || continue
      cur="$(yq -r "$t_path" "$t_file")"
      if [[ "$cur" != "$tag" ]]; then
        write_service_tag "$t_file" "$t_repo" "$tag"
        assert_written "${t_file} ${t_path}" "$(yq -r "$t_path" "$t_file")" "$tag"
        contains "$t_chart" "${changed_charts[@]:-}" || changed_charts+=("$t_chart")
        if [[ -n "$t_parent" ]]; then
          contains "$t_parent" "${touched_parents[@]:-}" || touched_parents+=("$t_parent")
        fi
      fi
    done
  done < <(manifest_repos)

  if (( ${#changed_charts[@]} == 0 )); then
    echo "nothing to do (already in sync)"
    return 0
  fi

  local chart_dir old_v new_v
  for chart_dir in "${changed_charts[@]}"; do
    old_v="$(chart_version "${chart_dir}/Chart.yaml")"
    new_v="$(bump_patch "$old_v")"
    write_chart_version "${chart_dir}/Chart.yaml" "$new_v"
    assert_written "${chart_dir}/Chart.yaml version" "$(chart_version "${chart_dir}/Chart.yaml")" "$new_v"
    bumped_pairs+=("${chart_dir}=${new_v}")
    echo "bumped ${chart_dir}/Chart.yaml: ${old_v} -> ${new_v}"
  done

  local parent_dir pair pchart pver child_name old_p new_p
  for parent_dir in "${touched_parents[@]:-}"; do
    [[ -z "$parent_dir" ]] && continue
    for pair in "${bumped_pairs[@]}"; do
      pchart="${pair%=*}"
      pver="${pair#*=}"
      [[ "$(dirname "$pchart")" == "${parent_dir}/charts" ]] || continue
      child_name="$(basename "$pchart")"
      write_dependency_version "${parent_dir}/Chart.yaml" "$child_name" "$pver"
      assert_written "${parent_dir}/Chart.yaml dependency ${child_name} version" "$(dep_version "${parent_dir}/Chart.yaml" "$child_name")" "$pver"
    done
    old_p="$(chart_version "${parent_dir}/Chart.yaml")"
    new_p="$(bump_patch "$old_p")"
    write_chart_version "${parent_dir}/Chart.yaml" "$new_p"
    assert_written "${parent_dir}/Chart.yaml version" "$(chart_version "${parent_dir}/Chart.yaml")" "$new_p"
    echo "bumped ${parent_dir}/Chart.yaml: ${old_p} -> ${new_p}"
    helm dependency update "$parent_dir" >/dev/null
    echo "ran: helm dependency update ${parent_dir}"
  done
}

check_manifest_drift() {
  local mismatches=()
  local repo tag a_tag row t_repo t_file t_path t_chart t_parent cur

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    tag="$(manifest_tag "$repo")"

    a_tag="$(artifact_tag "$repo")"
    if [[ -z "$a_tag" ]]; then
      mismatches+=("MISSING ARTIFACT ENTRY: ${repo} has no imageMirror.images[destRepository==${repo}] in ${ARTIFACT_VALUES}")
    elif [[ "$a_tag" != "$tag" ]]; then
      mismatches+=("TAG MISMATCH: ${ARTIFACT_VALUES} imageMirror entry for ${repo} has '${a_tag}', manifest has '${tag}'")
    fi

    for row in "${TARGETS[@]}"; do
      IFS='|' read -r t_repo t_file t_path t_chart t_parent <<<"$row"
      [[ "$t_repo" == "$repo" ]] || continue
      cur="$(yq -r "$t_path" "$t_file")"
      if [[ "$cur" != "$tag" ]]; then
        mismatches+=("TAG MISMATCH: ${t_file} ${t_path} has '${cur}', manifest has '${tag}'")
      fi
    done
  done < <(manifest_repos)

  if (( ${#mismatches[@]} > 0 )); then
    printf '  - %s\n' "${mismatches[@]}"
    return 1
  fi
  echo "OK"
}

check_version_constraints() {
  local mismatches=()
  local parent_chart_yaml parent_dir name child_chart_yaml child_ver constraint_ver

  for parent_chart_yaml in charts/*/Chart.yaml; do
    parent_dir="$(dirname "$parent_chart_yaml")"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      child_chart_yaml="${parent_dir}/charts/${name}/Chart.yaml"
      if [[ ! -f "$child_chart_yaml" ]]; then
        mismatches+=("BROKEN DEPENDENCY: ${parent_chart_yaml} declares local dependency '${name}' but ${child_chart_yaml} does not exist")
        continue
      fi
      child_ver="$(chart_version "$child_chart_yaml")"
      constraint_ver="$(dep_version "$parent_chart_yaml" "$name")"
      if [[ "$child_ver" != "$constraint_ver" ]]; then
        mismatches+=("VERSION CONSTRAINT MISMATCH: ${parent_chart_yaml} depends on ${name}==\"${constraint_ver}\" but ${child_chart_yaml} is version ${child_ver}")
      fi
    done < <(yq -r '.dependencies[]? | select((.repository // "") == "") | .name' "$parent_chart_yaml")
  done

  if (( ${#mismatches[@]} > 0 )); then
    printf '  - %s\n' "${mismatches[@]}"
    return 1
  fi
  echo "OK"
}

# Unchanged from this script's original, pre-manifest form: helm-templates
# every chart (including third-party images) and regex-scans rendered
# `image:` lines, comparing against charts/straiker-artifact/values.yaml as
# the reference. Complements the two checks above, which only ever look at
# 5 known Straiker-owned repos at 5 known static locations — this one catches
# anything that actually renders differently, for any image, third-party or
# not.
check_render_drift() {
python3 - <<'PY'
import pathlib
import re
import subprocess
import sys
from collections import defaultdict

repo_root = pathlib.Path.cwd()
charts_root = repo_root / "charts"
artifact_values = charts_root / "straiker-artifact" / "values.yaml"

if not artifact_values.exists():
    print(f"ERROR: missing {artifact_values}", file=sys.stderr)
    sys.exit(1)


def normalize_repo(repo: str) -> str:
    repo = repo.strip()
    repo = repo.replace("https://", "").replace("http://", "")
    parts = repo.split("/")
    if len(parts) > 1 and (("." in parts[0]) or (":" in parts[0]) or parts[0] == "localhost"):
        parts = parts[1:]
    if parts and parts[0] in {"onprem-base", "onprem-pro"}:
        parts = parts[1:]
    return "/".join(parts)


def split_image_ref(image: str):
    image = image.strip().strip('"').strip("'")
    if "@" in image:
        repo, digest = image.split("@", 1)
        return repo, f"@{digest}"
    slash = image.rfind("/")
    colon = image.rfind(":")
    if colon > slash:
        return image[:colon], image[colon + 1 :]
    return image, ""


artifact_sources: dict[str, set[str]] = defaultdict(set)
current_source = None
for raw in artifact_values.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    m_source = re.match(r"^-?\s*source:\s*(\S+)\s*$", line.replace("- source:", "source:"))
    if m_source:
        current_source = m_source.group(1).strip('"').strip("'")
        continue
    m_tag = re.match(r"^tag:\s*(\S+)\s*$", line)
    if m_tag and current_source:
        tag = m_tag.group(1).strip('"').strip("'")
        artifact_sources[normalize_repo(current_source)].add(tag)
        current_source = None

chart_dirs = []
for chart_yaml in charts_root.rglob("Chart.yaml"):
    chart_dir = chart_yaml.parent
    rel = chart_dir.relative_to(repo_root).as_posix()
    if rel.startswith("charts/straiker-artifact"):
        continue
    chart_dirs.append(chart_dir)

chart_dirs.sort()

found_by_norm: dict[tuple[str, str], set[str]] = defaultdict(set)
raw_by_norm: dict[tuple[str, str], set[str]] = defaultdict(set)
render_failures = []

image_pattern = re.compile(r'^\s*image:\s*("?)([^"\s]+)\1\s*$', re.MULTILINE)

for chart_dir in chart_dirs:
    rel = chart_dir.relative_to(repo_root).as_posix()
    cmd = [
        "helm",
        "template",
        "lint-artifacts",
        str(chart_dir),
        "--set",
        "global.dockerRegistry=",
        "--set",
        "global.modelBucket=lint-model-bucket",
        "--set",
        "global.infraNamespace=straiker",
        "--set",
        "cloudProvider=none",
        "--set",
        "db.host=postgres.straiker.svc.cluster.local",
        "--set",
        "postgres.storage.storageClassName=gp3",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        render_failures.append((rel, proc.stderr.strip() or proc.stdout.strip()))
        continue

    for m in image_pattern.finditer(proc.stdout):
        raw_img = m.group(2).strip()
        repo, tag = split_image_ref(raw_img)
        norm_repo = normalize_repo(repo)
        key = (norm_repo, tag)
        found_by_norm[key].add(rel)
        raw_by_norm[key].add(raw_img)

gaps = []
for (norm_repo, tag), charts in sorted(found_by_norm.items()):
    if not tag:
        gaps.append(("missing-tag", norm_repo, tag, charts))
        continue
    expected_tags = artifact_sources.get(norm_repo)
    if not expected_tags:
        gaps.append(("missing-repo", norm_repo, tag, charts))
        continue
    if tag not in expected_tags:
        gaps.append(("tag-mismatch", norm_repo, tag, charts))

if not gaps and not render_failures:
    print("OK")
else:
    for kind, repo, tag, charts in gaps:
        charts_s = ", ".join(sorted(charts))
        if kind == "missing-repo":
            print(f"  - [MISSING REPO] {repo}:{tag} (charts: {charts_s})")
        elif kind == "tag-mismatch":
            expected = ", ".join(sorted(artifact_sources.get(repo, set())))
            print(f"  - [TAG MISMATCH] {repo}:{tag} (expected one of: {expected}) (charts: {charts_s})")
        elif kind == "missing-tag":
            print(f"  - [MISSING TAG] {repo} (charts: {charts_s})")
    for rel, err in render_failures:
        print(f"  - [RENDER FAILED] {rel}: {err.splitlines()[0] if err else 'render failed'}")

if gaps or render_failures:
    sys.exit(1)
PY
}

FAILED=0

if $FIX; then
  echo "=== Applying charts/image-tags.yaml fixes ==="
  fix_manifest_drift
  echo
fi

echo "=== Image tag manifest check (charts/image-tags.yaml) ==="
check_manifest_drift || FAILED=1
echo

echo "=== Chart dependency version-constraint check ==="
check_version_constraints || FAILED=1
echo

echo "=== Rendered-image drift check (vs charts/straiker-artifact) ==="
check_render_drift || FAILED=1

exit "$FAILED"
