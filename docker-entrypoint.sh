#!/usr/bin/env bash
#
# entrypoint.sh – dynamically compute JVM memory settings inside a container,
#                 trigger OOM dumps and upload them to S3.
#
# Usage:
#   Before you run this script, you can export the following environment variables:
#
#     PROFILE               Spring profile to activate (e.g. dev, prod). Required.
#     ARTIFACT_NAME         The application JAR file name (e.g. app.jar). Required.
#     S3_BUCKET_BACKUP      S3 bucket where OOM dumps will be uploaded. Required for makedump.
#     TAG_APPLICATION_NAME  Application tag used in the S3 path (e.g. my-service). Required for makedump.
#     JAVA_THREAD_COUNT     Number of threads to reserve stack memory for (default: 200).
#     XSS_KB                Per‐thread stack size in KiB (default: 256).
#
# Example:
#   export PROFILE=prod
#   export ARTIFACT_NAME=myapp.jar
#   export S3_BUCKET_BACKUP=my-backup-bucket
#   export TAG_APPLICATION_NAME=myapp
#   export JAVA_THREAD_COUNT=150
#   export XSS_KB=384
#   ./entrypoint.sh
#
# You can also invoke the helper directly:
#   ./entrypoint.sh makedump <PID>
#

# -----------------------------------------------------------------------------
# 1. Detect cgroup version and read container memory limit (bytes → MiB)
# -----------------------------------------------------------------------------
detect_cgroup_version() {
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
# 2. Calculate heap settings and off-heap caps with an 8% reserve
# -----------------------------------------------------------------------------
# percentages
heap_pct_init=30       # initial heap = 30% of heap budget
heap_pct_max=60        # max heap     = 60% of heap budget
reserve_pct=8          # reserve 8% for OS, dumps, JVM shell, etc.

# fixed off-heap regions (MiB)
METASP_MB=$(( mem_mb / 8 ))   # 12.5% for Metaspace
DIRECT_MB=$(( mem_mb / 8 ))   # 12.5% for DirectMemory
CODECACHE_MB=128              # MiB for CodeCache
CCSPACE_MB=64                 # MiB for CompressedClassSpace

# thread stack total (MiB)
# Per‐thread stack size in KiB (can be overridden via XSS_KB env var, default: 256 KiB)
XSS_KB=${XSS_KB:-256}

# Approximate maximum number of threads your app may spawn
# (override via JAVA_THREAD_COUNT env var; default: 200)
THREAD_COUNT=${JAVA_THREAD_COUNT:-200}

# Total memory reserved for all thread stacks in MiB:
# THREAD_COUNT × XSS_KB (KiB) ÷ 1024
STACK_MB=$(( THREAD_COUNT * XSS_KB / 1024 ))

# compute totals
offheap_mb=$(( METASP_MB + DIRECT_MB + CODECACHE_MB + CCSPACE_MB + STACK_MB ))
reserve_mb=$(( mem_mb * reserve_pct / 100 ))
heap_budget_mb=$(( mem_mb - offheap_mb - reserve_mb ))

if (( heap_budget_mb <= 0 )); then
  echo "[ERROR] off-heap + reserve (${reserve_pct}%) exceeds container RAM!"
  exit 1
fi

# derive Xms and Xmx from remaining budget
XMS_MB=$(( heap_budget_mb * heap_pct_init / 100 ))
XMX_MB=$(( heap_budget_mb * heap_pct_max  / 100 ))

echo "[ENTRYPOINT] JVM heap budget: ${heap_budget_mb} MiB → Xms=${XMS_MB}m, Xmx=${XMX_MB}m"
echo "[ENTRYPOINT] Off-heap caps: Metaspace=${METASP_MB}m, Direct=${DIRECT_MB}m, CodeCache=${CODECACHE_MB}m, CCSpace=${CCSPACE_MB}m, ThreadStacks=${STACK_MB}m"
echo "[ENTRYPOINT] Reserve (${reserve_pct}%): ${reserve_mb} MiB"

# -----------------------------------------------------------------------------
# 3. OOM dump function triggered by OnOutOfMemoryError
# -----------------------------------------------------------------------------
make_dump() {
  pid=$1
  host=$HOSTNAME
  ts=$(date +%Y%m%d-%H%M%S)

  echo "[$(date)] Generating thread dump via jattach…"
  jattach "$pid" threaddump   > "/tmp/${host}.threaddump"     2>&1 || true

  echo "[$(date)] Generating heap dump via jattach…"
  jattach "$pid" dumpheap     "/tmp/${host}.dumpheap"       2>&1 || true

  echo "[$(date)] Generating heap dump via jcmd…"
  jcmd "$pid" GC.heap_dump    "/tmp/${host}-jcmd.dumpheap"  2>&1 || true

  echo "[$(date)] Generating thread dump via jcmd…"
  jcmd "$pid" Thread.print    > "/tmp/${host}-jcmd.threaddump" 2>&1 || true

  # archive and upload
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
