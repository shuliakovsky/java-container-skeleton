#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# 1. Detect cgroup version and read container memory limit (bytes → MiB)
# -----------------------------------------------------------------------------
detect_cgroup_version() {
  # cgroup v2 has a controllers file
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] && echo 2 || echo 1
}

get_cgroup_memory_limit_bytes() {
  local ver file val
  ver=$(detect_cgroup_version)

  if [[ "$ver" == "2" ]]; then
    file=/sys/fs/cgroup/memory.max
    val=$(<"$file")
    [[ $val != "max" ]] && echo "$val" && return
  else
    file=/sys/fs/cgroup/memory/memory.limit_in_bytes
    [[ -r $file ]] && echo $(<"$file") && return
  fi

  # fallback to total host RAM
  awk '/MemTotal/ { print $2 * 1024; exit }' /proc/meminfo
}

mem_bytes=$(get_cgroup_memory_limit_bytes)
mem_mb=$(( mem_bytes / 1024 / 1024 ))

echo "[ENTRYPOINT] cgroup v$(detect_cgroup_version), container RAM limit: ${mem_mb} MiB"

# -----------------------------------------------------------------------------
# 2. Calculate Xms/Xmx and off-heap caps based on container RAM
# -----------------------------------------------------------------------------
heap_pct_init=30    # initial heap = 30% of container RAM
heap_pct_max=60     # max heap     = 60% of container RAM

XMS_MB=$(( mem_mb * heap_pct_init / 100 ))
XMX_MB=$(( mem_mb * heap_pct_max  / 100 ))

# fixed caps for off-heap regions
METASP_MB=$(( mem_mb / 8 ))   # 12.5% for Metaspace
DIRECT_MB=$(( mem_mb / 8 ))   # 12.5% for Direct memory
CODECACHE_MB=128              # MiB for CodeCache
CCSPACE_MB=64                 # MiB for CompressedClassSpace
XSS_KB=256                    # KiB per thread stack

echo "[ENTRYPOINT] JVM heap: Xms=${XMS_MB}m, Xmx=${XMX_MB}m"
echo "[ENTRYPOINT] Off-heap caps: Metaspace=${METASP_MB}m, Direct=${DIRECT_MB}m, CodeCache=${CODECACHE_MB}m, CCSpace=${CCSPACE_MB}m, ThreadStack=${XSS_KB}k"

# -----------------------------------------------------------------------------
# 3. OOM dump function triggered by OnOutOfMemoryError
# -----------------------------------------------------------------------------
make_dump() {
  export pid=$1
  host=$HOSTNAME
  ts=$(date +%Y%m%d-%H%M%S)

  echo "[$(date)] Generating thread dump via jattach…"
  jattach "$pid" threaddump   > "/tmp/${host}.threaddump"    2>&1 || true

  echo "[$(date)] Generating heap dump via jattach…"
  jattach "$pid" dumpheap     "/tmp/${host}.dumpheap"      2>&1 || true

  echo "[$(date)] Generating heap dump via jcmd…"
  jcmd "$pid" GC.heap_dump    "/tmp/${host}-jcmd.dumpheap" 2>&1 || true

  echo "[$(date)] Generating thread dump via jcmd…"
  jcmd "$pid" Thread.print    > "/tmp/${host}-jcmd.threaddump" 2>&1 || true

  # collect all dump files
  shopt -s nullglob
  dumps=( /tmp/${host}*.dumpheap /tmp/${host}*.threaddump /tmp/*.hprof )

  backup="/tmp/${host}-${ts}.dump.tar.gz"
  echo "[$(date)] Archiving dumps: ${dumps[*]} → ${backup}"
  tar -czvf "${backup}" "${dumps[@]}"

  echo "[$(date)] Uploading archive to S3…"
  aws s3 cp "${backup}" "s3://${S3_BUCKET_BACKUP}/JAVA_APP_DUMPS/${TAG_APPLICATION_NAME}/"

  echo "[$(date)] Killing process $pid"
  kill -9 "$pid"
}

if [[ "${1:-}" == "makedump" ]]; then
  make_dump "$2"
  exit 0
fi

# -----------------------------------------------------------------------------
# 4. Launch the main Java process with calculated JVM options
# -----------------------------------------------------------------------------
exec java \
  --enable-native-access=ALL-UNNAMED \
  -XX:+UseContainerSupport \
  -Xms${XMS_MB}m \
  -Xmx${XMX_MB}m \
  -XX:MaxMetaspaceSize=${METASP_MB}m \
  -XX:MaxDirectMemorySize=${DIRECT_MB}m \
  -XX:ReservedCodeCacheSize=${CODECACHE_MB}m \
  -XX:CompressedClassSpaceSize=${CCSPACE_MB}m \
  -Xss${XSS_KB}k \
  -XX:+UseG1GC \
  -XX:+UseStringDeduplication \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/tmp \
  -XX:OnOutOfMemoryError="/docker-entrypoint.sh makedump %p" \
  -jar -Dspring.profiles.active=${PROFILE} ${ARTIFACT_NAME}
