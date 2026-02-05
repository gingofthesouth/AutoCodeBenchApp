#!/usr/bin/env python3
"""
Download autocodebench.jsonl from Hugging Face (tencent/AutoCodeBenchmark).
Usage: python3 download_dataset.py <output_dir>
Writes output_dir/autocodebench.jsonl. Requires: pip install huggingface_hub
"""
import sys
import os

def main():
    if len(sys.argv) < 2:
        print("Usage: download_dataset.py <output_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "autocodebench.jsonl")
    try:
        from huggingface_hub import hf_hub_download
        path = hf_hub_download(
            repo_id="tencent/AutoCodeBenchmark",
            filename="autocodebench.jsonl",
            repo_type="dataset",
            local_dir=out_dir,
            local_dir_use_symlinks=False,
        )
        # hf_hub_download returns path to file; if we used local_dir it may already be there
        if os.path.abspath(path) != os.path.abspath(out_path):
            import shutil
            shutil.copy2(path, out_path)
        print(out_path)
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()
