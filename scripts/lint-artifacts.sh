#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is required." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 1
fi

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

print("=== Discovered images from ./charts (excluding straiker-artifact) ===")
for (norm_repo, tag) in sorted(found_by_norm.keys()):
    refs = ", ".join(sorted(raw_by_norm[(norm_repo, tag)]))
    charts = ", ".join(sorted(found_by_norm[(norm_repo, tag)]))
    suffix = f":{tag}" if tag and not tag.startswith("@") else tag
    print(f"- {norm_repo}{suffix}")
    print(f"  raw: {refs}")
    print(f"  charts: {charts}")

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

print("\n=== Gaps vs charts/straiker-artifact/values.yaml ===")
if not gaps:
    print("No gaps found.")
else:
    for kind, repo, tag, charts in gaps:
        charts_s = ", ".join(sorted(charts))
        if kind == "missing-repo":
            print(f"[MISSING REPO] {repo}:{tag} (charts: {charts_s})")
        elif kind == "tag-mismatch":
            expected = ", ".join(sorted(artifact_sources.get(repo, set())))
            print(f"[TAG MISMATCH] {repo}:{tag} (expected one of: {expected}) (charts: {charts_s})")
        elif kind == "missing-tag":
            print(f"[MISSING TAG] {repo} (charts: {charts_s})")

if render_failures:
    print("\n=== Charts skipped due to render errors ===")
    for rel, err in render_failures:
        print(f"- {rel}")
        print(f"  {err.splitlines()[0] if err else 'render failed'}")

if gaps or render_failures:
    sys.exit(1)
PY