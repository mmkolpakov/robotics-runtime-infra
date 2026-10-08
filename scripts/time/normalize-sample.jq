# chronyc -c tracking includes both reference ID and name before stratum/time.
def chrony:
  (gsub("[\r\n]+$"; "") | split(",")) as $v |
  if ($v | length) != 14 then error("expected one chronyc tracking CSV record")
  else
    ($v[3] | tonumber) as $reference_seconds |
    $v[13] as $leap |
    if (["Normal", "Insert second", "Delete second", "Not synchronised"] | index($leap)) == null
    then error("unknown Chrony leap status") else
    {
      source_unix_ms: ($reference_seconds * 1000),
      offset_ms: (($v[4] | tonumber) * 1000),
      drift_ppm: ($v[7] | tonumber),
      monotonic: (if $leap == "Not synchronised" then 0 else 1 end)
    }
    end
  end;

def field($name):
  [scan("(?m)^\\s*" + $name + "[ \\t]+([^\\s]+)[ \\t]*\\r?$") | .[0]] |
  if length == 1 then .[0] else error("missing or repeated PMC field: " + $name) end;

def ptp:
  . as $raw |
  # config/time/ptp4l.conf uses hardware timestamps (PHC/PTP timescale).
  # Never assume a fixed TAI-UTC offset or silently accept an unknown timescale.
  if field("ptpTimescale") != "1" or field("currentUtcOffsetValid") != "1"
  then error("PTP sample has no valid PTP-to-UTC conversion") else
    ($raw | field("currentUtcOffset") | tonumber) as $utc_offset |
    ($raw | field("ingress_time") | tonumber) as $ingress_ns |
    {
      source_unix_ms: ($ingress_ns / 1000000 - $utc_offset * 1000),
      offset_ms: (($raw | field("master_offset") | tonumber) / 1000000),
      drift_ppm: (($raw | field("cumulativeScaledRateOffset") | tonumber) * 1000000),
      monotonic: (if ($raw | field("gmPresent")) == "true" then 1 else 0 end)
    }
  end;

if length > 65536 then error("oversized time sample") else
  (if $protocol == "chrony" then chrony
   elif $protocol == "ptp" then ptp
   else error("unsupported time protocol") end) |
  if .source_unix_ms <= 0 and .monotonic != 0 then error("source timestamp is absent") else
    . + {observed_unix_ms: $observed_unix_ms}
  end
end
