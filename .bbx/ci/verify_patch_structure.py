#!/usr/bin/env python3
from __future__ import annotations
import re, sys
from pathlib import Path

patch=Path(sys.argv[1]).read_text(encoding="utf-8",errors="strict")
errors=[]
for n,line in enumerate(patch.splitlines(),1):
    if line.startswith("@@ ") and re.match(r"@@ -1(?:,|\s)",line):
        errors.append(f"line {n}: synthetic line-1 hunk forbidden: {line}")

required_context={
 "src/video_core/buffer_cache/buffer_cache.cpp":[
   "void BufferCache::ReadMemory(",
   "void BufferCache::DownloadBufferMemory(",
 ],
 "src/video_core/texture_cache/tile_manager.cpp":[
   "TileManager::Result TileManager::DetileImage(",
   "TileManager::Result TileManager::TileLinearBuffer(",
 ],
}
for path,needles in required_context.items():
    marker=f"diff --git a/{path} b/{path}"
    if marker not in patch:
        errors.append(f"missing section {path}"); continue
    sec=patch.split(marker,1)[1].split("diff --git a/",1)[0]
    for x in needles:
        if x not in sec:
            errors.append(f"{path}: missing named context {x}")

# Specifically forbid a skinny ambiguous TryWriteBacking hunk.
for hunk in re.split(r"(?=^@@ )",patch,flags=re.M):
    if "TryWriteBacking" in hunk and "void BufferCache::DownloadBufferMemory" not in hunk:
        errors.append("TryWriteBacking hunk is not anchored to DownloadBufferMemory")

if errors:
    print("PATCH_STRUCTURE_PASS=false")
    for e in errors: print("ERROR:",e)
    raise SystemExit(2)
print("PATCH_STRUCTURE_PASS=true")
