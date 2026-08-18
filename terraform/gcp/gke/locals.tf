locals {
  is_zonal = var.provision_strategy == "min"

  # Real, currently-UP zones for the region rather than guessing the
  # "<region>-a/b/c" naming convention -- not every region has that exact
  # set (some skip a letter), so this avoids picking a zone that doesn't
  # exist.
  available_zones = data.google_compute_zones.available.names

  # "min": zonal cluster (single control-plane replica, cheaper than GKE's
  # regional/HA control plane) pinned to the first available zone. "ha"/
  # "max": regional cluster (Google-managed HA control plane across zones
  # regardless) -- location only controls the control plane's placement,
  # not workload nodes, which node_locations below constrains separately.
  cluster_location = local.is_zonal ? local.available_zones[0] : var.region

  zone_count = {
    min = 1
    ha  = 2
    max = 3
  }[var.provision_strategy]

  # Zones the system node pool spans. Empty for "min" -- a zonal cluster's
  # nodes already live in cluster_location itself; node_locations would only
  # ever add *more* zones, which "min" specifically doesn't want. For "ha"/
  # "max" this is what actually determines total node count (node_count is
  # per-zone for a regional pool): var.system_node_count * len(this list).
  system_node_locations = local.is_zonal ? [] : slice(local.available_zones, 0, local.zone_count)
}
