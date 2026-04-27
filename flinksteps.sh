#!/usr/bin/env bash
# flinksteps.sh — Set up and test an Apache Flink cluster using Docker.
#
# This script is idempotent: running it multiple times is safe. It will
# clean up any prior `flink-jobmanager` / `flink-taskmanager` containers
# and the `flink-net` network before recreating them.
#
# Usage:  ./flinksteps.sh
#
# Prerequisites: Docker daemon running, port 8081 free.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# We pull from the daocloud.io Docker Hub mirror because the public
# registry-1.docker.io is rate-limited for unauthenticated pulls in this
# environment. The mirror serves the exact same image bytes.
MIRROR_IMAGE="docker.m.daocloud.io/library/flink:1.18-scala_2.12"
LOCAL_IMAGE="flink:1.18"
NETWORK="flink-net"
JM_NAME="flink-jobmanager"
TM_NAME="flink-taskmanager"
WEB_PORT="8081"

# ---------------------------------------------------------------------------
# Step 1: Sanity-check Docker
# ---------------------------------------------------------------------------
echo "[1/6] Checking Docker is available..."
docker --version >/dev/null

# ---------------------------------------------------------------------------
# Step 2: Tear down any previous run (idempotency)
# ---------------------------------------------------------------------------
# `docker rm -f` succeeds even if the container is missing when combined
# with `|| true`. Same for the network.
echo "[2/6] Removing any existing Flink containers / network..."
docker rm -f "$JM_NAME" "$TM_NAME" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Step 3: Pull the Flink image (only if not already present locally)
# ---------------------------------------------------------------------------
# `docker image inspect` returns non-zero when the image is missing — we
# use that as the trigger to pull. This makes reruns fast.
echo "[3/6] Ensuring Flink image is available..."
if ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
    echo "    Pulling $MIRROR_IMAGE (this may take a minute)..."
    docker pull "$MIRROR_IMAGE"
    # Tag the mirror image with a friendly name so the rest of the script
    # (and any docker-compose files) can reference plain `flink:1.18`.
    docker tag "$MIRROR_IMAGE" "$LOCAL_IMAGE"
else
    echo "    $LOCAL_IMAGE already present — skipping pull."
fi

# ---------------------------------------------------------------------------
# Step 4: Create the user-defined bridge network
# ---------------------------------------------------------------------------
# A dedicated network gives both containers automatic DNS so the
# TaskManager can resolve `jobmanager` by hostname.
echo "[4/6] Creating network $NETWORK..."
docker network create "$NETWORK" >/dev/null

# ---------------------------------------------------------------------------
# Step 5: Start JobManager and TaskManager
# ---------------------------------------------------------------------------
# FLINK_PROPERTIES is read by the official entrypoint and appended to
# /opt/flink/conf/flink-conf.yaml at container startup.
echo "[5/6] Starting JobManager..."
docker run -d \
    --name "$JM_NAME" \
    --network "$NETWORK" \
    --hostname jobmanager \
    -p "${WEB_PORT}:8081" \
    -e "FLINK_PROPERTIES=jobmanager.rpc.address: jobmanager" \
    "$LOCAL_IMAGE" jobmanager >/dev/null

echo "      Starting TaskManager (2 slots)..."
docker run -d \
    --name "$TM_NAME" \
    --network "$NETWORK" \
    -e "FLINK_PROPERTIES=jobmanager.rpc.address: jobmanager
taskmanager.numberOfTaskSlots: 2" \
    "$LOCAL_IMAGE" taskmanager >/dev/null

# ---------------------------------------------------------------------------
# Step 6: Wait for the cluster to be ready and run a smoke test
# ---------------------------------------------------------------------------
# The web UI / REST endpoint comes up after JM finishes initialisation.
# We poll /overview until it responds with valid JSON, then fire a
# WordCount example to prove end-to-end execution works.
echo "[6/6] Waiting for Flink REST API on port $WEB_PORT..."
for i in $(seq 1 30); do
    if curl -fsS "http://localhost:${WEB_PORT}/overview" >/dev/null 2>&1; then
        echo "      Cluster is up."
        break
    fi
    sleep 1
    if [[ $i -eq 30 ]]; then
        echo "ERROR: cluster did not become ready in 30s" >&2
        docker logs "$JM_NAME" | tail -50 >&2
        exit 1
    fi
done

echo
echo "Cluster overview:"
curl -s "http://localhost:${WEB_PORT}/overview"
echo
echo

# Run the bundled WordCount streaming example to verify task execution.
echo "Submitting WordCount smoke-test job..."
docker exec "$JM_NAME" flink run /opt/flink/examples/streaming/WordCount.jar \
    2>&1 | grep -E "JobID|finished|Runtime" || true

echo
echo "Done. Web UI: http://localhost:${WEB_PORT}"
echo "Tear down with: docker rm -f $JM_NAME $TM_NAME && docker network rm $NETWORK"
