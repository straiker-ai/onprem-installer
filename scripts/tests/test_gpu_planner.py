import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gpu_planner as gp  # noqa: E402

MODELS = json.loads((Path(__file__).resolve().parents[1] / "gpu-models.json").read_text())


def nodes(product, count_per_node, n_nodes, memory_gb=None):
    return [{"name": f"n{i}", "product": product, "count": count_per_node, "memory_gb": memory_gb} for i in range(n_nodes)]


class Projected(unittest.TestCase):
    def test_production_default_tiers_fit_without_sharing(self):
        out = gp.plan(MODELS, gp.project_inventory(MODELS))
        self.assertTrue(out["feasible"], out)
        self.assertEqual(out["sharing"], "none")
        self.assertEqual(out["gpus_used"], 10)
        thanos = [p for p in out["placements"] if p["model"] == "thanos"]
        self.assertTrue(all(p["gpu_product"] == "L40S" and "quantization" not in p["vllm"] for p in thanos))

    def test_each_model_lands_on_its_default_tier(self):
        out = gp.plan(MODELS, gp.project_inventory(MODELS))
        want = {m["name"]: m["default_gpu"] for m in MODELS["models"]}
        for p in out["placements"]:
            self.assertEqual(p["gpu_product"], want[p["model"]])

    def test_subset_and_replicas(self):
        doc = {**MODELS, "models": [m for m in MODELS["models"] if m["name"] == "vision"]}
        self.assertEqual(len(gp.project_inventory(doc, replicas=3)), 3)

    def test_no_mig_skips_mig(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 1), profile="test", allow_mig=False)
        self.assertNotEqual(out["sharing"], "mig")


class HelmSets(unittest.TestCase):
    def test_exclusive_plan_changes_nothing(self):
        out = gp.plan(MODELS, gp.project_inventory(MODELS))
        self.assertEqual(gp.helm_sets(out, "thanos"), [])

    def test_exclusive_but_too_small_gpu_still_quantizes(self):
        out = gp.plan(MODELS, nodes("L4", 1, 12), profile="test", allow_mig=False)
        self.assertEqual(out["sharing"], "none")
        self.assertEqual(gp.helm_sets(out, "thanos"), ["inferenceService.quantization=bitsandbytes"])
        self.assertEqual(gp.helm_sets(out, "vision"), [])

    def test_time_sliced_plan_sets_serving_and_slices(self):
        out = gp.plan(MODELS, nodes("L4", 1, 8), profile="test", allow_mig=False)
        self.assertEqual(out["sharing"], "time-slicing")
        sets = gp.helm_sets(out, "thanos")
        self.assertIn("inferenceService.quantization=bitsandbytes", sets)
        self.assertTrue(any(x.startswith("inferenceService.max_model_len=") for x in sets))
        self.assertGreaterEqual(gp.slices_needed(out), 2)


class Fleet(unittest.TestCase):
    def test_fleet_is_five_models_two_replicas(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 2))
        self.assertEqual(out["pods"], 10)


class A100(unittest.TestCase):
    def test_two_p4de_nodes_one_model_per_gpu(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 2))  # 16 GPUs for 10 pods
        self.assertTrue(out["feasible"])
        self.assertEqual(out["sharing"], "none")
        self.assertEqual(out["gpus_used"], 10)
        for p in out["placements"]:
            self.assertEqual(p["vllm"]["dtype"], "bfloat16")
            self.assertEqual(p["vllm"]["max_model_len"], "32768")
            self.assertNotIn("quantization", p["vllm"])

    def test_single_p4de_8_gpus_packs_with_mig(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 1), profile="test")  # 8 GPUs < 10 pods
        self.assertTrue(out["feasible"], out)
        self.assertEqual(out["sharing"], "mig")
        self.assertTrue(all(p["mig_profile"] for p in out["placements"]))

    def test_p4d_40gb_eight_gpus(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-40GB", 8, 1), profile="test")
        self.assertTrue(out["feasible"], out)
        self.assertEqual(out["sharing"], "mig")
        for p in out["placements"]:
            if p["model"] == "thanos":  # 30 GB does not fit a 20 GB slice: needs the whole 40 GB GPU
                self.assertEqual(p["mig_profile"], "7g.40gb")

    def test_replicas_never_share_a_gpu(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 2, 1), profile="test")
        seen = {}
        for p in out["placements"]:
            seen.setdefault((p["node"], p["gpu"]), []).append(p["model"])
        for models in seen.values():
            self.assertEqual(len(models), len(set(models)))


class SmallGpus(unittest.TestCase):
    def test_l4_time_slicing_quantizes_thanos(self):
        out = gp.plan(MODELS, nodes("L4", 1, 8), profile="test")
        self.assertTrue(out["feasible"], out)
        self.assertEqual(out["sharing"], "time-slicing")
        thanos = [p for p in out["placements"] if p["model"] == "thanos"]
        self.assertTrue(all(p["vllm"].get("quantization") == "bitsandbytes" for p in thanos))
        for p in out["placements"]:
            self.assertEqual(p["vllm"]["dtype"], "bfloat16")
            if p["model"] in ("vision", "wanda"):
                self.assertEqual(p["vllm"]["kv_cache_dtype"], "fp8")

    def test_a10g_works_like_l4(self):
        out = gp.plan(MODELS, nodes("A10G", 1, 8), profile="test")
        self.assertTrue(out["feasible"], out)

    def test_t4_uses_float16_and_no_fp8(self):
        small = {**MODELS, "models": [m for m in MODELS["models"] if m["name"] != "kev-agentic"]}
        out = gp.plan(small, nodes("T4", 1, 10), profile="test")
        self.assertTrue(out["feasible"], out)
        for p in out["placements"]:
            self.assertEqual(p["vllm"]["dtype"], "float16")
            self.assertNotIn("kv_cache_dtype", p["vllm"])

    def test_model_too_big_for_any_gpu_is_named(self):
        out = gp.plan(MODELS, nodes("T4", 1, 10), profile="test")
        self.assertFalse(out["feasible"])
        self.assertEqual(sorted(out["unplaced"]), ["kev-agentic-1", "kev-agentic-2"])
        self.assertIn("kev-agentic needs about", out["shortfall"])
        self.assertIn("largest GPU here is 16 GB", out["shortfall"])

    def test_not_enough_gpus_reports_shortfall(self):
        out = gp.plan(MODELS, nodes("A10G", 1, 2), profile="test")
        self.assertFalse(out["feasible"])
        self.assertTrue(out["unplaced"])
        self.assertIn("needs about", out["shortfall"])

    def test_forced_mode_is_respected(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 2), sharing="time-slicing", profile="test")
        self.assertEqual(out["sharing"], "time-slicing")


class ProductionNeverShares(unittest.TestCase):
    def test_production_is_the_default_profile(self):
        self.assertEqual(gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 2))["profile"], "production")

    def test_production_with_too_few_gpus_fails_instead_of_packing(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 1))  # 8 GPUs, 10 servers: test profile would pack with MIG
        self.assertFalse(out["feasible"])
        self.assertEqual(out["sharing"], "none")
        self.assertIn("one server per GPU: needs 10 GPUs (found 8)", out["shortfall"])

    def test_production_small_gpus_do_not_time_slice_or_quantize(self):
        out = gp.plan(MODELS, nodes("L4", 1, 12))  # 12 x 24 GB: enough GPUs, but thanos needs ~30 GB unquantized
        self.assertFalse(out["feasible"])
        self.assertEqual(sorted(out["unplaced"]), ["thanos-1", "thanos-2"])
        self.assertIn("thanos needs about 30 GB", out["shortfall"])
        self.assertIn("production needs a larger GPU", out["shortfall"])
        for p in out["placements"]:
            self.assertEqual(p["sharing"], "none")
            self.assertNotIn("quantization", p["vllm"])

    def test_production_fits_thanos_on_a_100_40gb_without_quantizing(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-40GB", 8, 2))
        self.assertTrue(out["feasible"], out)
        self.assertTrue(all("quantization" not in p["vllm"] for p in out["placements"]))

    def test_production_refuses_sharing_modes(self):
        for mode in ("mig", "time-slicing"):
            with self.assertRaises(ValueError):
                gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 2), sharing=mode)

    def test_production_never_places_two_servers_on_a_gpu(self):
        for hw in (nodes("A100-SXM4-80GB", 8, 2), nodes("A100-SXM4-40GB", 8, 2), nodes("L4", 1, 12), nodes("L40S", 1, 10)):
            out = gp.plan(MODELS, hw)
            gpus = [(p["node"], p["gpu"]) for p in out["placements"]]
            self.assertEqual(len(gpus), len(set(gpus)))
            self.assertTrue(all(p["sharing"] == "none" and p["mig_profile"] is None for p in out["placements"]))

    def test_test_profile_still_can_share(self):
        out = gp.plan(MODELS, nodes("A100-SXM4-80GB", 8, 1), profile="test")
        self.assertTrue(out["feasible"])
        self.assertEqual(out["sharing"], "mig")


class Discovery(unittest.TestCase):
    def test_from_nvidia_labels(self):
        doc = {"items": [{"metadata": {"name": "ip-1", "labels": {
            "nvidia.com/gpu.product": "NVIDIA-A100-SXM4-80GB", "nvidia.com/gpu.memory": "81920", "nvidia.com/gpu.count": "8"}},
            "status": {"allocatable": {"nvidia.com/gpu": "8"}}}]}
        self.assertEqual(gp.nodes_from_kubectl(doc), [{"name": "ip-1", "product": "NVIDIA-A100-SXM4-80GB", "count": 8, "memory_gb": 80.0}])

    def test_from_instance_type_when_labels_missing(self):
        doc = {"items": [{"metadata": {"name": "ip-2", "labels": {"node.kubernetes.io/instance-type": "g6.xlarge"}},
                          "status": {"allocatable": {"nvidia.com/gpu": "1"}}}]}
        self.assertEqual(gp.nodes_from_kubectl(doc)[0]["product"], "L4")

    def test_non_gpu_nodes_are_ignored(self):
        doc = {"items": [{"metadata": {"name": "cpu", "labels": {"node.kubernetes.io/instance-type": "m5.large"}}, "status": {}}]}
        self.assertEqual(gp.nodes_from_kubectl(doc), [])


class CustomerP4dPool(unittest.TestCase):
    """Customer installs: the whole fleet on p4d.24xlarge (8x A100 40 GB), one server per GPU."""

    def test_full_fleet_needs_two_p4d_nodes(self):
        nodes = gp.project_inventory(MODELS, node_type="p4d.24xlarge")
        self.assertEqual(len(nodes), 2)  # 5 models x 2 replicas = 10 servers -> ceil(10 / 8)
        out = gp.plan(MODELS, nodes)
        self.assertTrue(out["feasible"], out)
        self.assertEqual(out["sharing"], "none")
        self.assertEqual(out["gpus_used"], 10)
        self.assertTrue(all(p["gpu_product"] == "A100-SXM4-40GB" for p in out["placements"]))

    def test_thanos_unquantized_on_a100(self):
        out = gp.plan(MODELS, gp.project_inventory(MODELS, node_type="p4d.24xlarge"))
        thanos = [p for p in out["placements"] if p["model"] == "thanos"]
        self.assertEqual(len(thanos), 2)
        self.assertTrue(all("quantization" not in p["vllm"] for p in thanos))

    def test_nodes_needed_from_saved_plan(self):
        nodes = gp.project_inventory(MODELS, node_type="p4d.24xlarge")
        doc = {**gp.plan(MODELS, nodes), "source": "projected", "projected_nodes": nodes}
        self.assertEqual(gp.projected_nodes(doc), {"p4d.24xlarge": 2})
        self.assertIn("2 x p4d.24xlarge", gp.summary(doc))

    def test_one_model_fits_one_node(self):
        doc = {**MODELS, "models": [m for m in MODELS["models"] if m["name"] == "thanos"]}
        self.assertEqual(len(gp.project_inventory(doc, node_type="p4d.24xlarge")), 1)

    def test_unknown_node_type_is_refused(self):
        with self.assertRaises(ValueError):
            gp.project_inventory(MODELS, node_type="p9.huge")


if __name__ == "__main__":
    unittest.main()
