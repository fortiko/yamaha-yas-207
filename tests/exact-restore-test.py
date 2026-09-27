#!/usr/bin/env python3

import argparse
import json
import time
import urllib.parse
import urllib.request


def request(base_url, path, params=None):
    query = ""
    if params:
        query = "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(base_url + path + query, timeout=5) as response:
        body = response.read().decode()
    if body.startswith("failed"):
        raise RuntimeError(body.strip())
    return body


def state(base_url):
    with urllib.request.urlopen(base_url + "/state", timeout=5) as response:
        return json.load(response)


def send_intent(base_url, intent):
    return request(base_url, "/send", {"intent": json.dumps(intent)})


def send_commands(base_url, *commands):
    return request(base_url, "/send", {"commands": ",".join(commands)})


def refresh_volume(base_url):
    generation = state(base_url)["protocol"]["volume_status_generation"]
    send_commands(base_url, "report_volume")
    return wait_for(
        base_url,
        lambda s: s["protocol"]["volume_status_generation"] > generation,
        "explicit volume status",
    )


def set_volume(base_url, target):
    current = refresh_volume(base_url)
    delta = target - current["device_state"]["volume"]
    command = "volume_up" if delta > 0 else "volume_down"
    generation = current["protocol"]["volume_status_generation"]
    commands = [command] * abs(delta) + ["report_volume"]
    send_commands(base_url, *commands)
    return wait_for(
        base_url,
        lambda s: s["protocol"]["volume_status_generation"] > generation
        and s["device_state"].get("volume") == target,
        f"volume {target}",
    )


def set_mute(base_url, muted):
    current = refresh_volume(base_url)
    generation = current["protocol"]["volume_status_generation"]
    send_commands(
        base_url,
        "mute_on" if muted else "mute_off",
        "report_volume",
    )
    return wait_for(
        base_url,
        lambda s: s["protocol"]["volume_status_generation"] > generation
        and s["device_state"].get("mute") is muted,
        f"mute {muted}",
    )


def set_tv_state(base_url):
    generation = state(base_url)["protocol"]["status_generation"]
    send_commands(
        base_url,
        "set_input_tv",
        "clearvoice_on",
        "mute_off",
        "report_status",
    )
    return wait_for(
        base_url,
        lambda s: s["protocol"]["status_generation"] > generation
        and s["device_state"].get("input") == "tv"
        and s["device_state"].get("clearvoice") is True
        and s["device_state"].get("mute") is False,
        "saved TV state",
    )


def wait_for(base_url, predicate, description, timeout=10):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = state(base_url)
        if predicate(last):
            return last
        time.sleep(0.02)
    raise TimeoutError(f"timed out waiting for {description}; last state={last}")


def prepare_saved_state(base_url, saved_volume):
    send_intent(base_url, {"input": "analog", "mute": True})
    wait_for(
        base_url,
        lambda s: s["device_state"].get("input") == "analog"
        and s["device_state"].get("mute") is True,
        "silent analogue setup",
    )

    set_volume(base_url, saved_volume)
    set_mute(base_url, True)
    set_tv_state(base_url)


def run_case(base_url, saved_volume, music_volume, iteration):
    prepare_saved_state(base_url, saved_volume)

    request(
        base_url,
        "/start-session",
        {
            "name": "protocol-test",
            "intent": json.dumps({"input": "analog", "clearvoice": False}),
        },
    )
    wait_for(
        base_url,
        lambda s: s["session"]["active"]
        and s["device_state"].get("input") == "analog"
        and s["device_state"].get("clearvoice") is False,
        "active analogue session",
    )

    before_stop = set_volume(base_url, music_volume)
    before_stop = set_mute(base_url, False)

    started_at = time.monotonic()
    starting_volume_generation = before_stop["protocol"]["volume_status_generation"]
    request(base_url, "/stop-session", {"name": "protocol-test"})

    observations = []
    saw_restoring = False
    while time.monotonic() - started_at < 10:
        current = state(base_url)
        elapsed = time.monotonic() - started_at
        observations.append(
            (
                elapsed,
                current["device_state"].get("input"),
                current["device_state"].get("volume"),
                current["device_state"].get("mute"),
                current["session"]["restore_phase"],
                current["protocol"]["volume_status_generation"],
            )
        )
        saw_restoring = saw_restoring or current["session"]["restoring"]
        if saw_restoring and not current["session"]["restoring"]:
            break
        time.sleep(0.01)
    else:
        raise TimeoutError(f"restore did not finish; last observation={observations[-1]}")

    final = state(base_url)
    elapsed = time.monotonic() - started_at
    final_device = final["device_state"]
    errors = []
    if final_device.get("volume") != saved_volume:
        errors.append(f"volume={final_device.get('volume')} expected={saved_volume}")
    if final_device.get("input") != "tv":
        errors.append(f"input={final_device.get('input')} expected=tv")
    if final_device.get("clearvoice") is not True:
        errors.append(f"clearvoice={final_device.get('clearvoice')} expected=true")
    if final_device.get("mute") is not False:
        errors.append(f"mute={final_device.get('mute')} expected=false")
    if final["session"]["restore_error"] is not None:
        errors.append(f"restore_error={final['session']['restore_error']}")

    unsafe = [
        item
        for item in observations
        if item[1] == "tv" and item[2] != saved_volume
    ]
    if unsafe:
        errors.append(f"input switched before volume verification: {unsafe[0]}")

    volume_generations = (
        final["protocol"]["volume_status_generation"] - starting_volume_generation
    )
    result = "PASS" if not errors else "FAIL"
    print(
        f"{result} iteration={iteration} saved={saved_volume} music={music_volume} "
        f"final={final_device.get('volume')} elapsed={elapsed:.3f}s "
        f"volume_status_replies={volume_generations}"
    )
    if errors:
        raise AssertionError("; ".join(errors))
    return elapsed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()

    cases = [(5, 15), (10, 5), (15, 20), (20, 8)]
    elapsed = []
    for iteration in range(1, args.repeat + 1):
        for saved_volume, music_volume in cases:
            elapsed.append(
                run_case(
                    args.base_url,
                    saved_volume,
                    music_volume,
                    iteration,
                )
            )
    print(
        f"PASS total={len(elapsed)} max_restore={max(elapsed):.3f}s "
        f"mean_restore={sum(elapsed) / len(elapsed):.3f}s"
    )


if __name__ == "__main__":
    main()
