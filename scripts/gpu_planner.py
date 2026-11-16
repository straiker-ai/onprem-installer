#!/usr/bin/env python3
"""Plan where the local-vLLM model servers run on whatever GPUs the cluster has.

Pure function over (models, GPU inventory): no cluster access, so every hardware case is unit-testable offline.
    gpu_planner.py --inventory inv.json [--models gpu-models.json] [--sharing auto|none|time-slicing|mig] [--replicas N]
    kubectl get nodes -o json | gpu_planner.py --from-kubectl
Exit 0 = feasible plan printed as JSON; exit 2 = not enough GPU capacity (the JSON says how much is missing).

Profiles: `production` (the default, what customers get) runs exactly one model server per GPU: no time-slicing, no MIG,
and a --sharing request is refused. `test` is explicit opt-in and may pack servers onto shared GPUs (MIG on A100/H100,
time-slicing elsewhere) so a small cluster can run the whole fleet end to end.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

EXCLUSIVE_FILL = 0.95  # fraction of a GPU's memory one exclusive pod may plan to use
SHARED_FILL = 0.90  # fraction when several pods share (time-slicing / MIG slice)

# product-name fragment -> (memory_gb, compute capability, MIG-capable)
GPU_KINDS = {
    "A100-SXM4-80GB": (80, 8.0, True), "A100-80GB": (80, 8.0, True),
    "A100-SXM4-40GB": (40, 8.0, True), "A100-PCIE-40GB": (40, 8.0, True), "A100": (40, 8.0, True),
    "H100": (80, 9.0, True), "L40S": (48, 8.9, False), "L4": (24, 8.9, False),
    "A10G": (24, 8.6, False), "T4": (16, 7.5, False), "V100": (16, 7.0, False),
}
# EC2 instance type -> (product, gpus per node), used when the NVIDIA labels are absent
INSTANCE_GPUS = {
    "g4dn.xlarge": ("T4", 1), "g4dn.12xlarge": ("T4", 4), "g5.xlarge": ("A10G", 1), "g5.12xlarge": ("A10G", 4),
    "g5.48xlarge": ("A10G", 8), "g6.xlarge": ("L4", 1), "g6.12xlarge": ("L4", 4), "g6.48xlarge": ("L4", 8),
    "g6e.xlarge": ("L40S", 1), "g6e.2xlarge": ("L40S", 1), "g6e.4xlarge": ("L40S", 1), "g6e.12xlarge": ("L40S", 4), "p4d.24xlarge": ("A100-SXM4-40GB", 8),
    "p4de.24xlarge": ("A100-SXM4-80GB", 8), "p5.48xlarge": ("H100", 8),
}
# MIG profiles: name -> (compute slices of 7, memory GB)
MIG = {
    40: {"1g.5gb": (1, 5), "2g.10gb": (2, 10), "3g.20gb": (3, 20), "4g.20gb": (4, 20), "7g.40gb": (7, 40)},
    80: {"1g.10gb": (1, 10), "2g.20gb": (2, 20), "3g.40gb": (3, 40), "4g.40gb": (4, 40), "7g.80gb": (7, 80)},
}


@dataclass
class Gpu:
    node: str
    index: int
    product: str
    memory_gb: float
    cc: float
    mig: bool

    @property
    def key(self) -> str:
        return f"{self.node}/gpu{self.index}"

    @property
    def bf16(self) -> bool:
        return self.cc >= 8.0

    @property
    def fp8_kv(self) -> bool:
        return self.cc >= 8.0


@dataclass
class Pod:
    model: dict
    replica: int

    @property
    def name(self) -> str:
        return f"{self.model['name']}-{self.replica}"


@dataclass
class Plan:
    sharing: str
    placements: list = field(default_factory=list)
    unplaced: list = field(default_factory=list)
    notes: list = field(default_factory=list)

    @property
    def feasible(self) -> bool:
        return not self.unplaced


def classify(product: str, memory_gb: float | None) -> tuple[float, float, bool]:
    p = product.upper().replace("NVIDIA-", "")
    for frag, (mem, cc, mig) in GPU_KINDS.items():
        if frag.upper() in p:
            return (memory_gb or mem), cc, mig
    return (memory_gb or 16), 7.5, False  # unknown: conservative (no bf16, no MIG)


def expand_inventory(nodes: list[dict]) -> list[Gpu]:
    gpus = []
    for n in nodes:
        mem, cc, mig = classify(n["product"], n.get("memory_gb"))
        for i in range(int(n["count"])):
            gpus.append(Gpu(n["name"], i, n["product"], mem, cc, mig))
    return gpus


def footprint(model: dict, gpu_mem: float, allow_quant: bool = True) -> tuple[float, bool]:
    """(GB needed on a GPU of this size, quantized?). Quantize only when the full-precision size does not fit."""
    full = model["weights_gb"] + model["kv_gb"]
    if full <= gpu_mem * SHARED_FILL or not (allow_quant and model.get("can_quantize")):
        return full, False
    return model.get("quantized_gb", full), True


def vllm_args(model: dict, gpu: Gpu, need_gb: float, quantized: bool, share_mem_gb: float, exclusive: bool) -> dict:
    """vLLM settings from the hardware: dtype by compute capability, memory fraction relative to what the pod owns
    (the whole GPU for exclusive/time-sliced pods, the slice for MIG), context length by that memory."""
    if exclusive:
        fraction = 0.95 if share_mem_gb >= 40 else 0.90
        max_len = 32768 if share_mem_gb >= 40 else 16384 if share_mem_gb >= 20 else 8192
    else:
        fraction = min(0.90, round(need_gb / share_mem_gb + 0.02, 2))
        max_len = 16384 if share_mem_gb >= 20 else 8192
    args = {
        "dtype": "bfloat16" if gpu.bf16 else "float16",
        "max_model_len": str(max_len),
        "mem_fraction_static": f"{fraction:.2f}",
    }
    if quantized:
        args["quantization"] = "bitsandbytes"
    if model.get("multimodal") and gpu.fp8_kv:
        args["kv_cache_dtype"] = "fp8"
    if model.get("server") == "kev-server":
        args["server"] = "kev-server"
    return args


def pods_for(models: list[dict], replicas: int | None, default_replicas: int) -> list[Pod]:
    pods = []
    for m in models:
        for r in range(1, (replicas or m.get("replicas") or default_replicas) + 1):
            pods.append(Pod(m, r))
    return pods


def place_exclusive(pods: list[Pod], gpus: list[Gpu], allow_quant: bool = False) -> Plan:
    plan = Plan("none")
    free = sorted(gpus, key=lambda g: -g.memory_gb)
    for pod in sorted(pods, key=lambda p: -(p.model["weights_gb"] + p.model["kv_gb"])):
        # a projected node was made for exactly this server (its default tier): use it before any other GPU
        for g in sorted(free, key=lambda g: g.node != f"projected-{pod.name}"):
            need, q = footprint(pod.model, g.memory_gb, allow_quant)
            if need <= g.memory_gb * EXCLUSIVE_FILL:
                free.remove(g)
                plan.placements.append(_placement(pod, g, "none", None, need, q, g.memory_gb, True))
                break
        else:
            plan.unplaced.append(pod.name)
    return plan


def place_timeslice(pods: list[Pod], gpus: list[Gpu], allow_quant: bool = True) -> Plan:
    plan = Plan("time-slicing")
    used: dict[str, float] = {g.key: 0.0 for g in gpus}
    holds: dict[str, set] = {g.key: set() for g in gpus}
    order = sorted(gpus, key=lambda g: (-g.memory_gb, g.key))
    for pod in sorted(pods, key=lambda p: -(p.model["weights_gb"] + p.model["kv_gb"])):
        for g in order:
            need, q = footprint(pod.model, g.memory_gb, allow_quant)
            if pod.model["name"] in holds[g.key]:
                continue  # replicas of one model never share a GPU: that would defeat having two
            if used[g.key] + need <= g.memory_gb * SHARED_FILL:
                used[g.key] += need
                holds[g.key].add(pod.model["name"])
                plan.placements.append(_placement(pod, g, "time-slicing", None, need, q, g.memory_gb, False))
                break
        else:
            plan.unplaced.append(pod.name)
    return plan


def place_mig(pods: list[Pod], gpus: list[Gpu], allow_quant: bool = True) -> Plan:
    plan = Plan("mig")
    usable = [g for g in gpus if g.mig and g.memory_gb >= 40]
    if len(usable) != len(gpus):
        plan.unplaced = [p.name for p in pods]
        plan.notes.append("MIG needs every GPU to be an A100/H100")
        return plan
    state = {g.key: {"compute": 0, "mem": 0.0, "models": set()} for g in usable}
    for pod in sorted(pods, key=lambda p: -(p.model["weights_gb"] + p.model["kv_gb"])):
        placed = False
        for g in usable:
            table = MIG[80 if g.memory_gb >= 60 else 40]
            need, q = footprint(pod.model, g.memory_gb, allow_quant)
            st = state[g.key]
            if pod.model["name"] in st["models"]:
                continue
            for pname, (cs, mg) in sorted(table.items(), key=lambda kv: (kv[1][1], kv[1][0])):
                if mg * SHARED_FILL >= need and st["compute"] + cs <= 7 and st["mem"] + mg <= g.memory_gb:
                    st["compute"] += cs
                    st["mem"] += mg
                    st["models"].add(pod.model["name"])
                    plan.placements.append(_placement(pod, g, "mig", pname, need, q, mg, False))
                    placed = True
                    break
            if placed:
                break
        if not placed:
            plan.unplaced.append(pod.name)
    plan.notes.append("MIG layouts are checked against NVIDIA's slice table here; the installer re-checks with nvidia-smi")
    return plan


def _placement(pod: Pod, gpu: Gpu, sharing: str, mig_profile, need: float, quantized: bool, share_mem: float, exclusive: bool) -> dict:
    return {
        "pod": pod.name, "model": pod.model["name"], "replica": pod.replica, "node": gpu.node, "gpu": gpu.index,
        "gpu_product": gpu.product, "sharing": sharing, "mig_profile": mig_profile, "planned_gb": round(need, 1),
        "vllm": vllm_args(pod.model, gpu, need, quantized, share_mem, exclusive),
    }


PROFILES = ("production", "test")


def project_inventory(models_doc: dict, replicas: int | None = None, node_type: str | None = None) -> list[dict]:
    """The inventory Karpenter will create when no GPU node exists yet. Without node_type: one single-GPU node per
    server, of the model's default tier (test installs). With node_type (a multi-GPU EC2 type such as p4d.24xlarge,
    the customer GPU pool): as many of those nodes as the servers need, one server per GPU. Only valid for exclusive
    placement (nothing is shared on a node that does not exist)."""
    pods = pods_for(models_doc["models"], replicas, models_doc.get("default_replicas", 2))
    if node_type:
        if node_type not in INSTANCE_GPUS:
            raise ValueError(f"unknown GPU node type {node_type!r} (known: {', '.join(sorted(INSTANCE_GPUS))})")
        product, per_node = INSTANCE_GPUS[node_type]
        return [{"name": f"projected-{node_type}-{i + 1}", "product": product, "count": per_node, "memory_gb": None,
                 "instance_type": node_type} for i in range(math.ceil(len(pods) / per_node))]
    nodes = []
    for pod in pods:
        nodes.append({"name": f"projected-{pod.name}", "product": pod.model.get("default_gpu", "A10G"), "count": 1,
                      "memory_gb": None})
    return nodes


def projected_nodes(plan_doc: dict) -> dict:
    """{instance type: nodes} the plan's projected inventory needs (multi-GPU pools only; empty otherwise)."""
    out: dict = {}
    for n in plan_doc.get("projected_nodes", []):
        if n.get("instance_type"):
            out[n["instance_type"]] = out.get(n["instance_type"], 0) + 1
    return out


def plan(models_doc: dict, nodes: list[dict], sharing: str = "auto", replicas: int | None = None,
         profile: str = "production", allow_mig: bool = True) -> dict:
    if profile not in PROFILES:
        raise ValueError(f"profile must be one of {PROFILES}")
    if profile == "production" and sharing not in ("auto", "none"):
        raise ValueError(f"--sharing {sharing} is only available with the test profile: production runs one server per GPU")
    gpus = expand_inventory(nodes)
    pods = pods_for(models_doc["models"], replicas, models_doc.get("default_replicas", 2))
    attempts = {"none": place_exclusive, "mig": place_mig, "time-slicing": place_timeslice}
    # Production never packs GPUs and never quantizes: a customer whose GPUs are too small is told what to get.
    allow_quant = profile == "test"
    if profile == "production":
        order = ["none"]
    else:
        order = (["none"] + (["mig"] if allow_mig else []) + ["time-slicing"]) if sharing == "auto" else [sharing]
    best = None
    for mode in order:
        result = attempts[mode](pods, gpus, allow_quant)
        if result.feasible:
            best = result
            break
        if best is None or len(result.unplaced) < len(best.unplaced):
            best = result
    used = {(p["node"], p["gpu"]) for p in best.placements}
    out = {
        "profile": profile, "feasible": best.feasible, "sharing": best.sharing, "pods": len(pods), "gpus_available": len(gpus),
        "gpus_used": len(used), "placements": best.placements, "unplaced": best.unplaced, "notes": best.notes,
    }
    if not best.feasible:
        out["shortfall"] = _shortfall(models_doc, pods, gpus, profile)
    return out


def _shortfall(models_doc: dict, pods: list[Pod], gpus: list[Gpu], profile: str = "production") -> str:
    allow_quant = profile == "test"
    if not gpus:
        return "no GPU nodes found: provide GPU nodes (or let the installer create them)"
    gb = max(g.memory_gb for g in gpus)
    too_big = sorted({p.model["name"]: footprint(p.model, gb, allow_quant)[0] for p in pods
                      if footprint(p.model, gb, allow_quant)[0] > gb * EXCLUSIVE_FILL}.items())
    if too_big:  # a model that fits no GPU here is a hardware problem, not a count problem
        names = ", ".join(f"{n} needs about {need:.0f} GB" for n, need in too_big)
        hint = "; production needs a larger GPU (e.g. A100 40 GB or L40S 48 GB)" if profile == "production" else ""
        return f"{names} on one GPU; the largest GPU here is {gb:g} GB{hint}"
    total = sum(footprint(p.model, gb, allow_quant)[0] for p in pods)
    need = math.ceil(total / (gb * SHARED_FILL))
    if profile == "production":
        return (f"production runs one server per GPU: needs {len(pods)} GPUs (found {len(gpus)}). "
                f"Add GPUs, lower --replicas, or use --profile test for a shared-GPU trial")
    return f"needs about {need} GPUs of {gb:g} GB with sharing (found {len(gpus)}); {len(pods)} servers, {total:.0f} GB planned"


def helm_sets(plan_doc: dict, model: str) -> list[str]:
    """`--set` pairs for charts/straiker-inference when the plan packs GPUs (test profile). Exclusive placement returns
    nothing: the model keeps the settings SaaS validated for it. One release serves all replicas, so the plan's most
    constrained placement of that model (smallest context) is used for all of them."""
    mine = [p for p in plan_doc["placements"] if p["model"] == model]
    if not mine:
        return []
    quantized = next((p["vllm"]["quantization"] for p in mine if p["vllm"].get("quantization")), None)
    if plan_doc.get("sharing") in (None, "none"):  # one server per GPU keeps SaaS's settings, except a forced quantization
        return [f"inferenceService.quantization={quantized}"] if quantized else []
    worst = min(mine, key=lambda p: int(p["vllm"]["max_model_len"]))["vllm"]
    sets = {k: worst[k] for k in ("dtype", "max_model_len", "mem_fraction_static", "kv_cache_dtype") if worst.get(k)}
    if quantized:  # one release, one setting: if any replica must be quantized they all are
        sets["quantization"] = quantized
    return [f"inferenceService.{k}={v}" for k, v in sets.items()]


def summary(plan_doc: dict) -> str:
    """A short human-readable plan for the installer log."""
    lines = [f"GPU plan ({plan_doc['profile']} profile, {plan_doc['source']}): {plan_doc['pods']} model servers on "
             f"{plan_doc['gpus_used']} GPU(s), sharing={plan_doc['sharing']}"]
    if plan_doc.get("discovered"):
        found = ", ".join(f"{n['name']}: {n['count']}x {n['product']}" for n in plan_doc["discovered"])
        lines.append(f"  GPU nodes found: {found}")
    elif plan_doc["source"] == "projected" and projected_nodes(plan_doc):
        made = ", ".join(f"{n} x {t} ({INSTANCE_GPUS[t][1]} GPUs each)" for t, n in projected_nodes(plan_doc).items())
        lines.append(f"  Karpenter creates {made}: one server per GPU")
    elif plan_doc["source"] == "projected":
        lines.append("  No GPU node is needed yet: Karpenter creates one per server, on the tier each model is validated for")
    by_model: dict = {}
    for p in plan_doc["placements"]:
        by_model.setdefault(p["model"], []).append(p)
    for model, ps in by_model.items():
        extra = ", quantized" if any(p["vllm"].get("quantization") for p in ps) else ""
        lines.append(f"  {model}: {len(ps)} x {ps[0]['gpu_product']} ({ps[0]['planned_gb']} GB planned each){extra}")
    for n in plan_doc.get("notes", []):
        lines.append(f"  note: {n}")
    if not plan_doc["feasible"]:
        lines.append(f"  NOT FEASIBLE: {plan_doc.get('shortfall', '')}")
    return "\n".join(lines)


def slices_needed(plan_doc: dict) -> int:
    """Most servers planned onto one GPU (the time-slicing replica count the device plugin must advertise)."""
    per_gpu: dict = {}
    for p in plan_doc["placements"]:
        per_gpu[(p["node"], p["gpu"])] = per_gpu.get((p["node"], p["gpu"]), 0) + 1
    return max(per_gpu.values(), default=1)


def nodes_from_kubectl(doc: dict) -> list[dict]:
    nodes = []
    for item in doc.get("items", []):
        labels = item["metadata"].get("labels", {})
        alloc = int(item.get("status", {}).get("allocatable", {}).get("nvidia.com/gpu", 0) or 0)
        product = labels.get("nvidia.com/gpu.product")
        mem = labels.get("nvidia.com/gpu.memory")
        count = int(labels.get("nvidia.com/gpu.count", alloc or 0))
        inst = labels.get("node.kubernetes.io/instance-type", "")
        if not product and inst in INSTANCE_GPUS:
            product, count = INSTANCE_GPUS[inst][0], count or INSTANCE_GPUS[inst][1]
        if not product or not count:
            continue
        nodes.append({"name": item["metadata"]["name"], "product": product, "count": count,
                      "memory_gb": round(int(mem) / 1024, 1) if mem else None})
    return nodes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inventory")
    ap.add_argument("--from-kubectl", action="store_true", help="read `kubectl get nodes -o json` on stdin")
    ap.add_argument("--models", default=str(Path(__file__).with_name("gpu-models.json")))
    ap.add_argument("--profile", default="production", choices=list(PROFILES),
                    help="production (default): one server per GPU, never shared. test: may share GPUs")
    ap.add_argument("--sharing", default="auto", choices=["auto", "none", "time-slicing", "mig"],
                    help="test profile only")
    ap.add_argument("--replicas", type=int)
    ap.add_argument("--projected", action="store_true",
                    help="no GPU nodes yet: plan on the nodes Karpenter will create (each model's default tier)")
    ap.add_argument("--no-mig", action="store_true", help="never plan MIG (the installer does not partition GPUs)")
    ap.add_argument("--discover", action="store_true",
                    help="read `kubectl get nodes -o json` on stdin; plan on the GPU nodes found (test profile) or on the "
                         "projected default tiers (production, or no GPU node yet). The result says which and lists what was found")
    ap.add_argument("--helm-sets", nargs=2, metavar=("PLAN_JSON", "MODEL"),
                    help="print the inferenceService --set pairs for MODEL from a saved plan, one per line")
    ap.add_argument("--summary", metavar="PLAN_JSON", help="print a short readable summary of a saved plan")
    ap.add_argument("--slices", metavar="PLAN_JSON", help="print the time-slicing replica count a saved plan needs")
    ap.add_argument("--only", help="comma-separated model names to plan (default: the whole fleet)")
    ap.add_argument("--node-type", help="production projection on this multi-GPU EC2 type (e.g. p4d.24xlarge, the "
                                        "customer GPU pool) instead of one node per server on each model's default tier")
    ap.add_argument("--nodes-needed", metavar="PLAN_JSON",
                    help="print '<instance type> <nodes>' per multi-GPU type a saved projected plan needs")
    a = ap.parse_args(argv)
    if a.helm_sets:
        print("\n".join(helm_sets(json.loads(Path(a.helm_sets[0]).read_text()), a.helm_sets[1])))
        return 0
    if a.summary:
        print(summary(json.loads(Path(a.summary).read_text())))
        return 0
    if a.slices:
        print(slices_needed(json.loads(Path(a.slices).read_text())))
        return 0
    if a.nodes_needed:
        for t, n in projected_nodes(json.loads(Path(a.nodes_needed).read_text())).items():
            print(f"{t} {n}")
        return 0
    models_doc = json.loads(Path(a.models).read_text())
    if a.only:
        wanted = set(a.only.split(","))
        models_doc["models"] = [m for m in models_doc["models"] if m["name"] in wanted]
    discovered, source = [], "inventory"
    if a.node_type and a.node_type not in INSTANCE_GPUS:
        print(f"error: unknown GPU node type {a.node_type!r} (known: {', '.join(sorted(INSTANCE_GPUS))})", file=sys.stderr)
        return 1
    if a.discover:
        discovered = nodes_from_kubectl(json.load(sys.stdin))
        # production never shares, and Karpenter adds nodes as servers are scheduled, so existing nodes do not bound it
        use_cluster = a.profile == "test" and discovered
        nodes, source = ((discovered, "cluster") if use_cluster
                         else (project_inventory(models_doc, a.replicas, a.node_type), "projected"))
    elif a.projected:
        nodes, source = project_inventory(models_doc, a.replicas, a.node_type), "projected"
    else:
        nodes = nodes_from_kubectl(json.load(sys.stdin)) if a.from_kubectl else json.loads(Path(a.inventory).read_text())
    try:
        result = plan(models_doc, nodes, a.sharing, a.replicas, a.profile, allow_mig=not a.no_mig)
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    result["source"] = source
    result["discovered"] = discovered
    if source == "projected":
        result["projected_nodes"] = nodes
    json.dump(result, sys.stdout, indent=2)
    print()
    return 0 if result["feasible"] else 2


if __name__ == "__main__":
    sys.exit(main())
