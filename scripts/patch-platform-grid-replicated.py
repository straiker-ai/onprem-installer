#!/usr/bin/env python3
"""On-prem patch for the vendored charts/platform-grid (idempotent; run by sync-platform-charts.sh).

When ClickHouse runs as replicas + Keeper, grid's migrations must create Replicated* tables, but the
platform repo's migrations (shared with the SaaS ClickHouse Cloud service) use plain MergeTree-family
engines, and ClickHouse does not convert them (cloud_mode_engine is a no-op outside Cloud). So, behind
straiker.grid.migrations.replicatedEngines (default false: SaaS and single-replica installs unchanged),
an init container copies the migrations from the image and rewrites the engines, and ch-migrate reads
the rewritten copy through GRID_CH_MIGRATE_DIR. The ZooKeeper path/replica are the server defaults.
"""
import re
import sys

chart = sys.argv[1] if len(sys.argv) > 1 else "charts/platform-grid"
tmpl = f"{chart}/templates/05-migrate-job.yaml"
vals = f"{chart}/values.yaml"
MARK = "replicatedEngines"

t = open(tmpl).read()
if MARK not in t:
    image = '"{{ .Values.straiker.grid.migrations.image.registry }}/{{ .Values.straiker.grid.migrations.image.name }}:{{ .Values.straiker.grid.migrations.image.version }}"'
    init = f'''      {{{{- if $m.replicatedEngines }}}}
      initContainers:
        - name: replicate-engines
          image: {image}
          imagePullPolicy: {{{{ .Values.straiker.grid.migrations.image.pullPolicy }}}}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              cp /straiker/ch-goose/*.sql /work/
              for f in /work/*.sql; do
                sed -E -i 's/ENGINE[[:space:]]*=[[:space:]]*(Replacing|Aggregating|Summing|Collapsing|VersionedCollapsing)?MergeTree/ENGINE = Replicated\\1MergeTree/g' "$f"
              done
          volumeMounts:
            - {{ name: ch-goose, mountPath: /work }}
      {{{{- end }}}}
'''
    assert "      containers:\n" in t
    t = t.replace("      containers:\n", init + "      containers:\n", 1)

    env_anchor = "          env:\n"
    assert env_anchor in t
    t = t.replace(env_anchor, env_anchor + '''            {{- if $m.replicatedEngines }}
            - name: GRID_CH_MIGRATE_DIR
              value: /work
            {{- end }}
''', 1)

    anchor = "      {{- with .Values.straiker.grid.nodeSelector }}\n"
    assert anchor in t
    t = t.replace(anchor, '''          {{- if $m.replicatedEngines }}
          volumeMounts:
            - { name: ch-goose, mountPath: /work }
          {{- end }}
      {{- if $m.replicatedEngines }}
      volumes:
        - { name: ch-goose, emptyDir: {} }
      {{- end }}
''' + anchor, 1)
    open(tmpl, "w").write(t)

v = open(vals).read()
if MARK not in v:
    v2 = re.sub(r"(\n    migrations:\n      enabled: false\n)",
                r"\1      # On-prem: ClickHouse as replicas + Keeper. An init container rewrites the migrations' plain\n"
                r"      # MergeTree-family engines to Replicated* (see scripts/patch-platform-grid-replicated.py).\n"
                r"      replicatedEngines: false\n", v, count=1)
    assert v2 != v, "migrations block not found in values.yaml"
    open(vals, "w").write(v2)
print("platform-grid replicatedEngines patch applied")
