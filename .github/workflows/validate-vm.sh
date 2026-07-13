#!/usr/bin/env bash
set -euo pipefail

vm_root="$RUNNER_TEMP/windows-vm"
oem="$vm_root/oem"
shared="$vm_root/shared"
storage="$vm_root/storage"
container="winget-validation-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  rm -rf "$storage"
}
trap cleanup EXIT

mkdir -p "$RUNNER_TEMP/artifacts"
if [[ ! -e /dev/kvm ]]; then
  echo "::error::This GitHub-hosted Linux runner does not expose /dev/kvm"
  exit 1
fi

rm -rf "$vm_root"
mkdir -p "$oem/manifest" "$shared" "$storage"
cp -R "$(dirname "$MANIFEST_PATH")/." "$oem/manifest/"
cp .github/workflows/validate.ps1 .github/workflows/validate-bootstrap.ps1 \
  .github/workflows/analyses.json "$oem/"

jq -n \
  --arg arch "$ARCH" \
  --arg scope "$SCOPE" \
  --arg installerType "$INSTALLER_TYPE" \
  --arg token "$GITHUB_TOKEN" \
  '{arch: $arch, scope: $scope, installerType: $installerType, token: $token}' \
  > "$oem/config.json"

printf '%s\r\n' \
  '@echo off' \
  'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OEM\validate-bootstrap.ps1' \
  > "$oem/install.bat"

docker run --detach --name "$container" \
  --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN \
  --env VERSION=11l --env RAM_SIZE=8G --env CPU_CORES=4 --env DISK_SIZE=64G \
  --volume "$storage:/storage" --volume "$oem:/oem:ro" --volume "$shared:/shared" \
  --stop-timeout 120 \
  docker.io/dockurr/windows:6.00@sha256:5f8b87b0d135cb19834f052e8bf6479d1596f4cca1b5eb33937dad9b6fa0e06c \
  >/dev/null

deadline=$((SECONDS + 60 * 60))
next_log=$SECONDS
while [[ ! -f "$shared/exit-code.txt" ]]; do
  if ! docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
    docker logs "$container"
    echo "::error::Windows VM stopped before validation completed"
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    docker logs "$container"
    echo "::error::Windows VM validation timed out after 60 minutes"
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
  cat "$shared/github-output.txt" >> "$GITHUB_OUTPUT"
fi
cat "$shared/bootstrap.log" 2>/dev/null || true

exit_code="$(tr -d '\r\n ' < "$shared/exit-code.txt")"
if [[ "$exit_code" != 0 ]]; then
  echo "::error::Validation failed inside the Windows VM with exit code $exit_code"
  exit "$exit_code"
fi
