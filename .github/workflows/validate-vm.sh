#!/usr/bin/env bash
set -euo pipefail

vm_root="$RUNNER_TEMP/windows-vm"
oem="$vm_root/oem"
shared="$vm_root/shared"
storage="$vm_root/storage"
baseline="$RUNNER_TEMP/windows-arm64-baseline"
container="winget-validation-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
image="winget-validation-windows:${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  rm -rf "$storage"
}
trap cleanup EXIT

docker build --tag "$image" --file .github/workflows/validate-vm.Dockerfile .github/workflows

mkdir -p "$RUNNER_TEMP/artifacts"
docker_devices=(--device /dev/net/tun)
kvm=Y
if [[ -e /dev/kvm ]]; then
  docker_devices+=(--device /dev/kvm)
else
  kvm=N
  echo "::notice::KVM is unavailable; using multithreaded QEMU emulation"
fi

windows_version=11l
disk_size=64G
disk_cache=writeback
if [[ "$ARCH" == arm64 && "$kvm" == N ]]; then
  disk_size=32G
  disk_cache=unsafe
fi

rm -rf "$vm_root"
mkdir -p "$oem/manifest" "$shared" "$storage"
guest_files="$oem"
if [[ "$ARCH" == arm64 ]]; then
  test -s "$baseline/windows.qcow2"
  find "$baseline" -maxdepth 1 -type f ! -name 'windows.qcow2' -exec cp -a {} "$storage/" \;
  docker run --rm \
    --volume "$baseline:/baseline:ro" --volume "$storage:/storage" \
    --entrypoint qemu-img "$image" \
    create -f qcow2 -F qcow2 -b /baseline/windows.qcow2 /storage/windows.qcow2
  guest_files="$shared"
fi

mkdir -p "$guest_files/manifest"
cp -R "$(dirname "$MANIFEST_PATH")/." "$guest_files/manifest/"
cp .github/workflows/validate.ps1 .github/workflows/validate-bootstrap.ps1 \
  .github/workflows/install-validation-dependencies.ps1 \
  .github/workflows/analyses.json "$guest_files/"

jq -n \
  --arg arch "$ARCH" \
  --arg scope "$SCOPE" \
  --arg installerType "$INSTALLER_TYPE" \
  --arg token "$GITHUB_TOKEN" \
  '{arch: $arch, scope: $scope, installerType: $installerType, token: $token}' \
  > "$guest_files/config.json"

if [[ "$ARCH" != arm64 ]]; then
  printf '%s\r\n' \
    '@echo off' \
    'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OEM\validate-bootstrap.ps1' \
    > "$oem/install.bat"
fi

baseline_volume=()
if [[ "$ARCH" == arm64 ]]; then
  baseline_volume=(--volume "$baseline:/baseline:ro")
fi

docker run --detach --name "$container" \
  "${docker_devices[@]}" --cap-add NET_ADMIN \
  --env VERSION="$windows_version" --env RAM_SIZE=8G --env CPU_CORES=4 \
  --env DISK_SIZE="$disk_size" --env DISK_CACHE="$disk_cache" --env KVM="$kvm" \
  "${baseline_volume[@]}" \
  --volume "$storage:/storage" --volume "$oem:/oem:ro" --volume "$shared:/shared" \
  --stop-timeout 120 \
  "$image" \
  >/dev/null

timeout_minutes=60
if [[ "$ARCH" == arm64 && "$kvm" == N ]]; then
  timeout_minutes=17
fi
deadline=$((SECONDS + timeout_minutes * 60))
next_log=$SECONDS
while [[ ! -f "$shared/exit-code.txt" ]]; do
  if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
    docker logs "$container"
    echo "::error::Windows VM stopped before validation completed"
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    docker logs "$container"
    echo "::error::Windows VM validation timed out after $timeout_minutes minutes"
    exit 1
  fi
  if (( SECONDS >= next_log )); then
    docker logs --tail 20 "$container"
    next_log=$((SECONDS + 60))
  fi
  sleep 10
done

mkdir -p "$RUNNER_TEMP/artifacts"
cp -R "$shared/artifacts/." "$RUNNER_TEMP/artifacts/" 2>/dev/null || true
if [[ -f "$shared/github-output.txt" ]]; then
  tr -d '\r' < "$shared/github-output.txt" >> "$GITHUB_OUTPUT"
fi
cat "$shared/bootstrap.log" 2>/dev/null || true

exit_code="$(tr -d '\r\n ' < "$shared/exit-code.txt")"
if [[ "$exit_code" != 0 ]]; then
  echo "::error::Validation failed inside the Windows VM with exit code $exit_code"
  exit "$exit_code"
fi
