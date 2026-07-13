#!/usr/bin/env bash
set -euo pipefail

baseline="$RUNNER_TEMP/windows-arm64-baseline"
vm_root="$RUNNER_TEMP/windows-baseline-build"
oem="$vm_root/oem"
shared="$vm_root/shared"
container="winget-validation-baseline-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
image="winget-validation-windows:${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$baseline" "$vm_root"
mkdir -p "$baseline" "$oem" "$shared"
docker build --tag "$image" --file .github/workflows/validate-vm.Dockerfile .github/workflows

cp .github/workflows/prepare-validation-vm.ps1 \
  .github/workflows/validation-startup.ps1 \
  .github/workflows/install-validation-dependencies.ps1 "$oem/"
printf '%s\r\n' \
  '@echo off' \
  'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OEM\prepare-validation-vm.ps1' \
  > "$oem/install.bat"

docker run --detach --name "$container" \
  --device /dev/net/tun --cap-add NET_ADMIN \
  --env VERSION=11l --env RAM_SIZE=8G --env CPU_CORES=4 --env KVM=N \
  --env DISK_SIZE=32G --env DISK_FMT=qcow2 --env DISK_CACHE=unsafe \
  --volume "$baseline:/storage" --volume "$oem:/oem:ro" --volume "$shared:/shared" \
  --stop-timeout 120 "$image" >/dev/null

deadline=$((SECONDS + 150 * 60))
next_log=$SECONDS
while [[ ! -f "$shared/baseline-ready.txt" ]]; do
  if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
    docker logs "$container"
    echo "::error::Windows baseline VM stopped before preparation completed"
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    docker logs "$container"
    echo "::error::Windows baseline preparation timed out"
    exit 1
  fi
  if (( SECONDS >= next_log )); then
    docker logs --tail 20 "$container"
    next_log=$((SECONDS + 60))
  fi
  sleep 10
done

for _ in {1..30}; do
  docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true || break
  sleep 10
done
docker stop --time 120 "$container" >/dev/null 2>&1 || true
rm -f "$baseline/boot.iso"
test -s "$baseline/windows.qcow2"
du -sh "$baseline"
