def attributes($items):
  reduce ($items // [])[] as $item (
    {};
    .[$item.key] = (
      $item.value.stringValue //
      $item.value.boolValue //
      $item.value.intValue //
      $item.value.doubleValue
    )
  );

def absolute:
  if . < 0 then -. else . end;

def values($samples; $name):
  [$samples[] | select(.name == $name) | .value];

# Chrony tracking reference time includes up to 1s of deliberate randomization.
# This CI fixture budgets that uncertainty plus 1s for polling and export, just
# like the host-time producer. Preserve the reported source time and actual age.
def max_source_age_ms: 2000;

[
  .[] |
  .resourceMetrics[]? as $resource |
  $resource.scopeMetrics[]? as $scope |
  $scope.metrics[]? as $metric |
  (($metric.gauge.dataPoints // $metric.sum.dataPoints // [])[]) |
  {
    name: $metric.name,
    unit: $metric.unit,
    observed_at: (.timeUnixNano | tonumber),
    value: (
      if has("asDouble") then .asDouble
      elif has("asInt") then (.asInt | tonumber)
      else null
      end
    ),
    attributes: (
      attributes($resource.resource.attributes) *
      attributes($scope.scope.attributes) *
      attributes(.attributes)
    )
  } |
  select(.value != null)
] as $samples |
($window[0]) as $measurement_window |
($measurement_window.started_at_unix_nano | tonumber) as $window_start |
($measurement_window.finished_at_unix_nano | tonumber) as $window_end |
[
  "robotics.hardware.clock.offset",
  "robotics.hardware.clock.drift",
  "robotics.hardware.message.age",
  "robotics.hardware.clock.monotonic"
] as $required |
($samples | group_by(.observed_at)) as $points |
($required | sort) as $required_sorted |
$measurement_window.schema_version == "physical-attach-time-window.v1" and
$measurement_window.run_id == $run_id and
$measurement_window.workflow_run_id == $workflow_run_id and
$measurement_window.workflow_run_attempt == $workflow_run_attempt and
$measurement_window.source_revision == $source_revision and
$measurement_window.evidence_sha256 == $evidence_sha256 and
$window_start <= $window_end and
($window_end - $window_start) <= $max_window_ns and
$window_end <= ($now_ns + $future_tolerance_ns) and
($now_ns - $window_end) <= $max_age_ns and
all($samples[]; .observed_at >= $window_start and .observed_at <= $window_end) and
($samples | map(.name) | unique | sort) == $required_sorted and
($points | length) >= 1 and
all(
  $points[];
  (map(.name) | sort) == $required_sorted and
  length == 4 and
  (map(.attributes["robotics.clock.sample_unix_ms"]) | unique | length) == 1
) and
all(
  $samples[];
  .attributes["robotics.clock.sample_unix_ms"] as $source_ms |
  ($source_ms | type) == "number" and $source_ms > 0 and
  $source_ms <= (.observed_at / 1000000) and
  (.observed_at / 1000000 - $source_ms) <= max_source_age_ms and
  # An old record cannot be refreshed by rewriting only the collector timestamp
  # or by wrapping it in a new measurement window.
  ($now_ns / 1000000 - $source_ms) <= ($max_age_ns / 1000000 + max_source_age_ms) and
  (if .name == "robotics.hardware.message.age" then
    (.value - (.observed_at / 1000000 - $source_ms) | absolute) <= 1
   else true end)
) and
all(
  $samples[];
  .attributes["robotics.clock.sync_protocol"] == "chrony_ntp" and
  .attributes["robotics.clock.source"] == "chronyc_tracking"
) and
all(
  $samples[];
  if .name == "robotics.hardware.clock.offset" then .unit == "ms"
  elif .name == "robotics.hardware.clock.drift" then .unit == "ppm"
  elif .name == "robotics.hardware.message.age" then .unit == "ms"
  else .unit == "1"
  end
) and
(values($samples; "robotics.hardware.clock.offset") | map(absolute) | max) <= 5 and
(values($samples; "robotics.hardware.clock.drift") | map(absolute) | max) <= 20 and
(values($samples; "robotics.hardware.message.age") | min) >= 0 and
(values($samples; "robotics.hardware.message.age") | max) <= max_source_age_ms and
all(values($samples; "robotics.hardware.clock.monotonic")[]; . == 1)
