#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

if [[ $# -lt 2 || $# -gt 3 || (${3:-} != '' && ${3:-} != --stdin) ]]; then
  printf 'usage: sample.sh chrony|ptp OUTPUT_DIRECTORY [--stdin]\n' >&2
  exit 64
fi
protocol="$1"
sample_dir="$(cd -- "$2" && pwd -P)"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "${protocol}" in
  chrony) sample_name=chrony.log ;;
  ptp) sample_name=pmc.log ;;
  *) exit 64 ;;
esac
sample_path="${sample_dir}/${sample_name}"
for path in "${sample_path}" "${sample_path}.1"; do
  [[ ! -L "${path}" && (! -e "${path}" || -f "${path}") ]] || exit 73
done
umask 0027
temporary="$(mktemp "${sample_dir}/.${sample_name}.XXXXXX")"
trap 'rm -f -- "${temporary}" "${temporary}.sock"' EXIT

read_sample() {
  if [[ ${3:-} == --stdin ]]; then
    cat
  elif [[ ${protocol} == chrony ]]; then
    timeout 5 chronyc -c -n -h /run/robotics-time/chronyd.sock tracking
  else
    timeout 5 pmc -u -b 0 -i "${temporary}.sock" -s /run/robotics-time/ptp4lro \
      'GET TIME_STATUS_NP' 'GET TIME_PROPERTIES_DATA_SET'
  fi
}

read_sample "$@" | jq -b -R -s -c -e \
  --arg protocol "${protocol}" \
  --argjson observed_unix_ms "$(date -u +%s%3N)" \
  -f "${script_dir}/normalize-sample.jq" >"${temporary}"
chmod 0640 "${temporary}"
# Keep exactly the latest two complete samples. Bind the directory in Compose
# so the file receiver follows replacement inodes; a single-file bind cannot.
if [[ -f ${sample_path} ]]; then
  mv -f -- "${sample_path}" "${sample_path}.1"
fi
mv -f -- "${temporary}" "${sample_path}"
