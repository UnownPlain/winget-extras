FROM docker.io/dockurr/windows:6.00@sha256:5f8b87b0d135cb19834f052e8bf6479d1596f4cca1b5eb33937dad9b6fa0e06c

# The ARM64 variant does not include ipcalc, although its network startup
# script requires it to validate and calculate the guest subnet.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ipcalc \
    && sed -i 's/-accel tcg,thread=multi/-accel tcg,thread=multi,tb-size=1024/' /run/proc.sh \
    && rm -rf /var/lib/apt/lists/*
