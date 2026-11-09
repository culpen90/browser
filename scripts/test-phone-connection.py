#!/usr/bin/env python3
"""Verify both connection directions using the real Mac model and an Android emulator."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Android emulator serial, e.g. emulator-5580")
    args = parser.parse_args()
    if not re.fullmatch(r"emulator-[0-9]+", args.serial):
        parser.error("Use an emulator; the fixture temporarily replaces its test app's pairing state.")
    root = Path(__file__).resolve().parents[1]
    # Finish compilation before the phone's time-limited pairing fixture starts.
    subprocess.run(["swift", "build", "--build-tests"], cwd=root, check=True)
    adb = ["adb", "-s", args.serial]
    package = "com.culpen.browser.debug"
    for apk in ["debug/app-debug.apk", "androidTest/debug/app-debug-androidTest.apk"]:
        subprocess.run(adb + ["install", "-r", str(root / "android/app/build/outputs/apk" / apk)], check=True, capture_output=True)
    marker_names = ["phone-invite-link.txt", "phone-invite-code.txt", "phone-invite-paired.txt",
                    "phone-invite-awaiting-attach.txt", "phone-invite-model-answer.txt", "phone-invite-done.txt"]
    subprocess.run(adb + ["exec-out", "run-as", package, "rm", "-f"] + ["files/" + name for name in marker_names],
                   check=True, capture_output=True)

    def app_file(name):
        try:
            result = subprocess.run(adb + ["exec-out", "run-as", package, "cat", "files/" + name],
                                    capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            return b""
        # Some adb exec-out versions report exit zero for a failing remote cat.
        # Callers must validate exact contents, never use nonempty output as a marker.
        return result.stdout.strip() if result.returncode == 0 else b""

    processes = []
    forwarded = False
    with tempfile.TemporaryDirectory(prefix="browser-peer-") as directory:
        directory = Path(directory)
        link = directory / "phone"
        android_log = directory / "android.log"
        swift_log = directory / "swift.log"
        try:
            subprocess.run(adb + ["forward", "--no-rebind", "tcp:38766", "tcp:38766"], check=True, capture_output=True)
            forwarded = True
            with android_log.open("wb") as output:
                android = subprocess.Popen(adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
                    "com.culpen.browser.PhoneInviteTest#receiveComputerOfferAndAttachViaPresence", "-e",
                    "phoneInviteFixture", "true", package + ".test/androidx.test.runner.AndroidJUnitRunner"], stdout=output, stderr=subprocess.STDOUT)
            processes.append(android)
            start = time.monotonic()
            while True:
                value = app_file("phone-invite-link.txt")
                if value.startswith(b"browseragent://phone?"):
                    link.write_bytes(value)
                    link.chmod(0o600)
                    break
                if time.monotonic() - start > 35:
                    raise RuntimeError("The Android invitation inbox did not start.")
                time.sleep(0.25)
            env = dict(os.environ, BROWSER_TEST_PHONE_INBOX_FILE=str(link))
            with swift_log.open("wb") as output:
                swift = subprocess.Popen(["swift", "test", "--skip-build", "--filter", "BrowserAgentPhoneInboxFixtureTests"],
                                         cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
            processes.append(swift)
            verified = False
            ready = False
            deadline = time.monotonic() + 155
            while time.monotonic() < deadline:
                code_file = Path(str(link) + ".code")
                if not verified and code_file.exists():
                    phone_code = app_file("phone-invite-code.txt")
                    if re.fullmatch(rb"[0-9]{6}", phone_code):
                        if phone_code != code_file.read_bytes().strip():
                            raise RuntimeError("The devices displayed different verification codes.")
                        verified = True
                        print("Verified matching pairing codes.", flush=True)
                if verified and not ready and app_file("phone-invite-awaiting-attach.txt") == b"ready":
                    Path(str(link) + ".ready-to-attach").write_text("ready")
                    ready = True
                    print("Verified model handoff and answer; selecting the phone from the Mac.", flush=True)
                expected = b"paired, answered, and attached through outbound presence"
                if ready and app_file("phone-invite-done.txt") == expected:
                    Path(str(link) + ".done").write_text("done")
                    print("Verified Mac-side selection restored the phone's model connection.", flush=True)
                    break
                if swift.poll() is not None or android.poll() is not None:
                    raise RuntimeError("A fixture stopped before reciprocal selection completed.")
                time.sleep(0.25)
            else:
                raise RuntimeError("Reciprocal connection verification timed out.")
            swift.wait(timeout=25)
            android.wait(timeout=25)
            if swift.returncode != 0 or "OK (1 test)" not in android_log.read_text():
                raise RuntimeError("A fixture reported failure after connection verification.")
            print("Both reciprocal connection fixtures passed using the real Mac model.", flush=True)
        except Exception:
            for log in [swift_log, android_log]:
                if log.exists():
                    print("\n" + log.name + ":\n" + "\n".join(log.read_text(errors="replace").splitlines()[-24:]), flush=True)
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            if processes:
                subprocess.run(adb + ["shell", "am", "force-stop", package], capture_output=True)
            if forwarded:
                subprocess.run(adb + ["forward", "--remove", "tcp:38766"], capture_output=True)


if __name__ == "__main__":
    main()
