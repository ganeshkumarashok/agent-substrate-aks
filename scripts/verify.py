#!/usr/bin/env python3
import argparse
import datetime
import json
import pathlib
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request


def run(*args, timeout=120):
    return subprocess.run(
        args, check=True, capture_output=True, text=True, timeout=timeout
    ).stdout


def parse_counter(text, expected):
    match = re.fullmatch(
        r"hello from: ([^|\s]+) \| preserved memory count: (\d+) "
        r"\| preserved file counter: (\d+)\n?",
        text,
    )
    if not match:
        raise RuntimeError(f"Unexpected counter response: {text!r}")
    ip, memory, filesystem = match.groups()
    if (int(memory), int(filesystem)) != (expected, expected):
        raise RuntimeError(
            f"State continuity failure: expected {expected}/{expected}, "
            f"got {memory}/{filesystem}"
        )
    return {"ip": ip, "memoryCount": int(memory), "fileCount": int(filesystem)}


def actor_status(name):
    actor = json.loads(run(
        "kubectl", "ate", "get", "actor", name,
        "-a", "ate-demo-counter", "-o", "json",
    ))
    return actor["status"]


def wait_state(name, state, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = actor_status(name)
        if status["state"] == state:
            return status
        if status["state"] == "ACTOR_STATE_CRASHED":
            raise RuntimeError(f"Actor crashed: {json.dumps(status)}")
        time.sleep(1)
    raise RuntimeError(f"Actor did not reach {state}: {json.dumps(status)}")


def suspend(name):
    run("kubectl", "ate", "suspend", "actor", name, "-a", "ate-demo-counter")
    status = wait_state(name, "ACTOR_STATE_SUSPENDED")
    if not status.get("externalSnapshot") or status.get("workerAssignment"):
        raise RuntimeError(f"Suspended actor lacks a detached durable snapshot: {status}")


def health():
    result = {"namespaces": {}, "publicApplicationServices": 0}
    for namespace in ("ate-system", "ate-demo-counter", "podcertificate-controller-system", "otel-system"):
        pods = json.loads(run("kubectl", "-n", namespace, "get", "pods", "-o", "json"))["items"]
        if not pods:
            raise RuntimeError(f"No pods in required namespace {namespace}")
        ready = 0
        restarts = 0
        for pod in pods:
            status = pod["status"]
            if status["phase"] == "Succeeded":
                continue
            if status["phase"] != "Running" or not any(
                c["type"] == "Ready" and c["status"] == "True"
                for c in status.get("conditions", [])
            ):
                raise RuntimeError(f"Unhealthy pod: {namespace}/{pod['metadata']['name']}")
            ready += 1
            restarts += sum(c["restartCount"] for c in status.get("containerStatuses", []))
        services = json.loads(run(
            "kubectl", "-n", namespace, "get", "services", "-o", "json"
        ))["items"]
        for service in services:
            spec = service["spec"]
            if spec["type"] != "ClusterIP" or spec.get("externalIPs"):
                raise RuntimeError(f"Public application service: {namespace}/{service['metadata']['name']}")
        result["namespaces"][namespace] = {"readyPods": ready, "containerRestarts": restarts}
    pool = json.loads(run(
        "kubectl", "-n", "ate-demo-counter", "get", "deployment", "counter", "-o", "json"
    ))
    if pool["status"].get("readyReplicas", 0) != pool["spec"]["replicas"]:
        raise RuntimeError("Not every requested counter worker is ready")
    result["workerReplicas"] = pool["spec"]["replicas"]
    return result


def verify(receipt_path, port):
    started = datetime.datetime.now(datetime.timezone.utc)
    if receipt_path.exists():
        previous = json.loads(receipt_path.read_text())
        history = receipt_path.parent / "verification-history"
        history.mkdir(exist_ok=True)
        (history / f"{previous['actor']}.json").write_text(receipt_path.read_text())
    actor = f"aks-proof-{started.strftime('%Y%m%d%H%M%S')}"
    isolation_actor = actor + "-isolated"
    receipt = {
        "startedAt": started.isoformat(), "actor": actor, "isolationActor": isolation_actor,
        "cyclesRequested": 5, "cyclesCompleted": 0, "observations": [],
        "phase": "preflight", "outcome": "in_progress",
        "restoration": {"portForwardStopped": False, "proofActorsSuspended": False},
    }

    def save(phase):
        receipt["phase"] = phase
        receipt["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        temporary = receipt_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary.replace(receipt_path)
        print(f"{receipt['updatedAt']} {phase}; completed={receipt['cyclesCompleted']}/5", flush=True)

    save("checking cluster health")
    log_path = receipt_path.parent / "logs" / "verification-port-forward.log"
    with log_path.open("w") as log:
        forward = None
        try:
            receipt["initialHealth"] = health()
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", port))
            forward = subprocess.Popen([
                "kubectl", "-n", "ate-system", "port-forward",
                "--address", "127.0.0.1", "svc/atenet-router", f"{port}:80",
            ], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 30
            while True:
                if forward.poll() is not None:
                    raise RuntimeError(f"Port-forward failed; see {log_path}")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        break
                except (ConnectionRefusedError, TimeoutError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError(f"Port-forward readiness timed out; see {log_path}")
                    time.sleep(0.2)

            def request(name, expected):
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/", data=b"", method="POST",
                    headers={"ate-target-actor": f"ate-demo-counter/{name}"},
                )
                before = time.monotonic()
                with urllib.request.urlopen(req, timeout=90) as response:
                    observation = parse_counter(response.read().decode(), expected)
                observation["requestSeconds"] = round(time.monotonic() - before, 3)
                status = wait_state(name, "ACTOR_STATE_RUNNING")
                observation["workerPod"] = status["workerAssignment"]["workerPod"]
                observation["node"] = status["assignedNode"]
                return observation

            run("kubectl", "ate", "create", "actor", actor, "-a", "ate-demo-counter", "--template", "counter")
            save("actor created; making first routed request")
            receipt["observations"].append(request(actor, 1))
            original_worker = receipt["observations"][0]["workerPod"]

            for cycle in range(1, 6):
                save(f"suspending for cycle {cycle}")
                suspend(actor)
                if cycle == 1:
                    save("replacing original worker after durable suspend")
                    run("kubectl", "-n", "ate-demo-counter", "delete", "pod", original_worker, "--wait=true", "--timeout=90s")
                    run("kubectl", "-n", "ate-demo-counter", "rollout", "status", "deployment/counter", "--timeout=5m", timeout=330)
                    receipt["replacedWorker"] = original_worker
                observation = request(actor, cycle + 1)
                if cycle == 1 and observation["workerPod"] == original_worker:
                    raise RuntimeError("Restore unexpectedly used the deleted worker")
                receipt["observations"].append(observation)
                receipt["cyclesCompleted"] = cycle
                save(f"cycle {cycle} memory and filesystem continuity verified")

            run("kubectl", "ate", "create", "actor", isolation_actor, "-a", "ate-demo-counter", "--template", "counter")
            receipt["isolatedObservation"] = request(isolation_actor, 1)
            if receipt["isolatedObservation"]["workerPod"] == receipt["observations"][-1]["workerPod"]:
                raise RuntimeError("Concurrent isolated actor shared the first actor's worker")
            suspend(isolation_actor)
            suspend(actor)
            receipt["finalActorState"] = actor_status(actor)["state"]
            receipt["finalIsolationState"] = actor_status(isolation_actor)["state"]
            receipt["restoration"]["proofActorsSuspended"] = True
            receipt["finalHealth"] = health()
            receipt["outcome"] = "passed"
            save("functional verification passed")
        except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired,
                urllib.error.URLError, OSError, KeyError, ValueError) as error:
            receipt["outcome"] = "failed"
            receipt["error"] = str(error)
            if isinstance(error, subprocess.CalledProcessError):
                receipt["commandStdout"] = error.stdout
                receipt["commandStderr"] = error.stderr
            if isinstance(error, urllib.error.HTTPError):
                receipt["httpResponseBody"] = error.read().decode(errors="replace")
            save("verification failed; proof actors retained for diagnosis")
            raise
        finally:
            if forward is not None:
                forward.terminate()
                try:
                    forward.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    forward.kill()
                    forward.wait(timeout=10)
            receipt["restoration"]["portForwardStopped"] = True
            save("temporary port-forward stopped")
    print(json.dumps({
        "outcome": receipt["outcome"], "cyclesCompleted": receipt["cyclesCompleted"],
        "workerReplacementVerified": "replacedWorker" in receipt,
        "actor": actor, "receipt": str(receipt_path),
    }), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=pathlib.Path, required=True)
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    verify(args.receipt, args.port)
