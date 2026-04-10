"""Download GN binary for the current platform. Falls back to source build."""
import os, platform, shutil, subprocess, sys, time, urllib.request, zipfile

def main():
    gn_rev = sys.argv[1] if len(sys.argv) > 1 else None
    if not gn_rev:
        print("Usage: download_gn.py <gn_revision>")
        sys.exit(1)

    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "darwin":
        plat = f"mac-{'arm64' if machine == 'arm64' else 'amd64'}"
    elif system == "windows":
        plat = "windows-amd64"
    else:
        plat = f"linux-{'arm64' if machine == 'aarch64' else 'amd64'}"

    url = f"https://chrome-infra-packages.appspot.com/dl/gn/gn/{plat}/+/git_revision:{gn_rev}"

    # Try CIPD download
    for attempt in range(3):
        try:
            print(f"CIPD attempt {attempt+1}: {url}")
            urllib.request.urlretrieve(url, "gn.zip")
            with zipfile.ZipFile("gn.zip") as zf:
                zf.extractall("gn_bin")
            gn_exe = os.path.join("gn_bin", "gn.exe" if system == "windows" else "gn")
            os.chmod(gn_exe, 0o755)
            print(f"GN downloaded successfully")
            return
        except Exception as e:
            print(f"  Failed: {e}")
            if attempt < 2:
                time.sleep(5 * (attempt + 1))

    # Fallback: build from source
    print("CIPD unavailable, building GN from source...")

    # Try git clone first
    gn_cloned = False
    try:
        subprocess.run(["git", "clone", "https://gn.googlesource.com/gn.git", "gn_src"],
                       check=True, timeout=120)
        gn_cloned = True
    except Exception as e:
        print(f"Git clone failed: {e}")

    # Fallback: HTTPS archive download
    if not gn_cloned:
        print("Downloading GN source via HTTPS archive...")
        try:
            urllib.request.urlretrieve(
                "https://gn.googlesource.com/gn/+archive/refs/heads/main.tar.gz",
                "gn_src.tar.gz"
            )
            os.makedirs("gn_src", exist_ok=True)
            import tarfile
            with tarfile.open("gn_src.tar.gz") as tf:
                tf.extractall("gn_src")
            # Init git repo (gen.py needs git describe)
            subprocess.run(["git", "init"], cwd="gn_src", check=False, capture_output=True)
            subprocess.run(["git", "add", "-A"], cwd="gn_src", check=False, capture_output=True)
            subprocess.run(["git", "commit", "-m", "init", "--allow-empty"],
                           cwd="gn_src", check=False, capture_output=True)
            subprocess.run(["git", "tag", "initial-commit"],
                           cwd="gn_src", check=False, capture_output=True)
            gn_cloned = True
        except Exception as e:
            print(f"HTTPS archive download also failed: {e}")
            sys.exit(1)

    # Build GN
    env = os.environ.copy()
    if system == "windows":
        # gen.py hardcodes -mmacosx-version-min on mac; on Windows it should be fine
        pass

    subprocess.run([sys.executable, "build/gen.py", "--allow-warnings"],
                   cwd="gn_src", check=True, env=env)
    subprocess.run(["ninja", "-C", "out", "gn"],
                   cwd="gn_src", check=True, env=env)

    os.makedirs("gn_bin", exist_ok=True)
    gn_name = "gn.exe" if system == "windows" else "gn"
    shutil.copy2(os.path.join("gn_src", "out", gn_name), os.path.join("gn_bin", gn_name))
    print("GN built from source successfully")

if __name__ == "__main__":
    main()
