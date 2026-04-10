"""Clone pdfium source via HTTPS when git_url fails (e.g., Windows PBP workers)."""
import os, subprocess, sys, tarfile, urllib.request, tempfile

PDFIUM_COMMIT = "79d84a59fb337f5ae4c1c9fee60677c29a310f46"
PDFIUM_URL = f"https://chromium.googlesource.com/pdfium/+archive/{PDFIUM_COMMIT}.tar.gz"

def main():
    if os.path.exists("DEPS"):
        print("Source already present, skipping.")
        return

    print(f"Downloading pdfium source from {PDFIUM_URL}")
    tmp = tempfile.mktemp(suffix=".tar.gz")

    for attempt in range(3):
        try:
            urllib.request.urlretrieve(PDFIUM_URL, tmp)
            print(f"Downloaded ({os.path.getsize(tmp)} bytes)")
            break
        except Exception as e:
            print(f"Attempt {attempt+1} failed: {e}")
            if attempt == 2:
                raise

    # googlesource archives extract to current directory (no top-level folder)
    print("Extracting...")
    with tarfile.open(tmp) as tf:
        tf.extractall(".")

    os.remove(tmp)

    # Initialize git repo (some build scripts use git commands)
    subprocess.run(["git", "init"], check=False, capture_output=True)
    subprocess.run(["git", "add", "-A"], check=False, capture_output=True)
    subprocess.run(["git", "commit", "-m", "init", "--allow-empty"],
                   check=False, capture_output=True)

    print("Pdfium source ready.")

if __name__ == "__main__":
    main()
