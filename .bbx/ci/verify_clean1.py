#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re
from pathlib import Path
from dataclasses import dataclass, asdict

REQUIRED_FILES = [
    "src/common/bb_blackbox/schema.h",
    "src/common/bb_blackbox/recorder.h",
    "src/common/bb_blackbox/recorder.cpp",
    "src/common/bb_blackbox/sites.h",
    "src/common/bb_blackbox/identity.cpp",
    "src/video_core/renderer_vulkan/bb_gpu_trace.h",
    "src/video_core/renderer_vulkan/bb_gpu_trace.cpp",
    "tools/bb_blackbox/decode.py",
]
FUNCTION_RULES = [
    ("src/video_core/renderer_vulkan/vk_scheduler.cpp", r"\bScheduler::Scheduler\s*\(", 1, 1, "Scheduler::Scheduler"),
    ("src/video_core/renderer_vulkan/vk_scheduler.cpp", r"\bScheduler::SubmitExecution\s*\(", 1, 1, "Scheduler::SubmitExecution"),
    ("src/video_core/renderer_vulkan/vk_scheduler.cpp", r"\bScheduler::Finish\s*\(", 1, 1, "Scheduler::Finish"),
    ("src/video_core/renderer_vulkan/vk_scheduler.cpp", r"\bScheduler::Wait\s*\(", 1, 1, "Scheduler::Wait"),
    ("src/video_core/buffer_cache/buffer_cache.cpp", r"\bBufferCache::SynchronizeBuffer\s*\(", 1, 1, "BufferCache::SynchronizeBuffer"),
    ("src/video_core/buffer_cache/buffer_cache.cpp", r"\bBufferCache::SynchronizeBufferFromImage\s*\(", 1, 1, "BufferCache::SynchronizeBufferFromImage"),
    ("src/video_core/renderer_vulkan/vk_rasterizer.cpp", r"\bRasterizer::Draw\s*\(", 1, 1, "Rasterizer::Draw"),
    ("src/video_core/renderer_vulkan/vk_rasterizer.cpp", r"\bRasterizer::DrawIndirect\s*\(", 1, 1, "Rasterizer::DrawIndirect"),
    ("src/video_core/texture_cache/texture_cache.cpp", r"\bTextureCache::InvalidateMemory\s*\(", 1, 1, "TextureCache::InvalidateMemory"),
    ("src/video_core/texture_cache/texture_cache.cpp", r"\bTextureCache::InvalidateMemoryFromGPU\s*\(", 1, 1, "TextureCache::InvalidateMemoryFromGPU"),
]
FORBIDDEN_CANDIDATES = [
    "C1_HOST_LIFETIME","C2_GPU_CONVERSION_REUSE","C3_BB_LIGHTGRID_MATCH",
    "C4_UMA_SCRATCH_POOL","C5_BUFFER_READBACK_WINDOW","C6_FETCH_PARSE_CACHE",
]

@dataclass
class Check:
    name: str
    ok: bool
    detail: str

def strip_cpp_comments_and_strings(s: str) -> str:
    out=[]; i=0; n=len(s); state="code"; quote=""
    while i<n:
        c=s[i]; d=s[i+1] if i+1<n else ""
        if state=="code":
            if c=="/" and d=="/": out += "  "; i+=2; state="line"; continue
            if c=="/" and d=="*": out += "  "; i+=2; state="block"; continue
            if c in ("'", '"'): quote=c; out.append(" "); i+=1; state="string"; continue
            out.append(c); i+=1
        elif state=="line":
            if c=="\n": out.append("\n"); state="code"
            else: out.append(" ")
            i+=1
        elif state=="block":
            if c=="*" and d=="/": out += "  "; i+=2; state="code"
            else: out.append("\n" if c=="\n" else " "); i+=1
        else:
            if c=="\\" and i+1<n: out += "  "; i+=2
            elif c==quote: out.append(" "); i+=1; state="code"
            else: out.append("\n" if c=="\n" else " "); i+=1
    return "".join(out)

def function_body(text: str, sig_rx: str):
    m=re.search(sig_rx,text)
    if not m: return None
    start_par=text.find("(",m.start())
    depth=0; i=start_par
    while i<len(text):
        if text[i]=="(": depth+=1
        elif text[i]==")":
            depth-=1
            if depth==0: i+=1; break
        i+=1
    init_depth=0
    while i<len(text):
        c=text[i]
        if c=="{":
            if init_depth==0:
                j=i-1
                while j>=0 and text[j].isspace(): j-=1
                if j>=0 and (text[j].isalnum() or text[j] in "_>"):
                    init_depth=1; i+=1; continue
                body_start=i; break
            init_depth+=1
        elif c=="}" and init_depth: init_depth-=1
        i+=1
    else: return None
    depth=0
    for j in range(body_start,len(text)):
        if text[j]=="{": depth+=1
        elif text[j]=="}":
            depth-=1
            if depth==0: return text[body_start:j+1]
    return None

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("root",type=Path)
    ap.add_argument("--json",type=Path)
    a=ap.parse_args()
    root=a.root.resolve(); checks=[]

    missing=[p for p in REQUIRED_FILES if not (root/p).is_file()]
    checks.append(Check("REQUIRED_FILES",not missing,f"missing={missing!r}"))

    for rel,rx,lo,hi,label in FUNCTION_RULES:
        p=root/rel
        if not p.exists():
            checks.append(Check("MANDATORY_SYMBOL:"+label,False,f"{rel}: missing file")); continue
        code=strip_cpp_comments_and_strings(p.read_text(encoding="utf-8",errors="replace"))
        count=len(re.findall(rx,code))
        checks.append(Check("MANDATORY_SYMBOL:"+label,lo<=count<=hi,
                            f"{rel}: definitions={count}, expected={lo}..{hi}"))

    host=root/"src/core/file_sys/backends/host_fs.cpp"
    host_code=host.read_text(encoding="utf-8",errors="replace") if host.exists() else ""
    checks.append(Check("SAVEFIX_S1","FileShareFlag::ShareReadWrite" in host_code,
                        "host_fs.cpp must explicitly request FileShareFlag::ShareReadWrite"))

    uma=root/"src/video_core/renderer_vulkan/bb_uma_policy.h"
    uma_code=uma.read_text(encoding="utf-8",errors="replace") if uma.exists() else ""
    for label,rx in [
        ("C_WRITEBACK_UNSAFE",r"C_WRITEBACK_UNSAFE"),
        ("GcWritebackEnabled_false",r"GcWritebackEnabled\s*=\s*false"),
        ("BufferGcEnabled_false",r"BufferGcEnabled\s*=\s*false"),
        ("DiscardStaleEnabled_false",r"DiscardStaleEnabled\s*=\s*false"),
    ]:
        checks.append(Check("UMA_INVARIANT:"+label,bool(re.search(rx,uma_code)),rx))

    src_text=""
    if (root/"src").exists():
        for p in (root/"src").rglob("*"):
            if p.suffix in (".cpp",".cc",".cxx",".h",".hpp"):
                src_text += "\n"+p.read_text(encoding="utf-8",errors="replace")
    found=[x for x in FORBIDDEN_CANDIDATES if x in src_text]
    checks.append(Check("NO_C1_C6",not found,f"found={found!r}"))

    gpu_raw=""
    for rel in ["src/video_core/renderer_vulkan/bb_gpu_trace.cpp",
                "src/video_core/renderer_vulkan/bb_gpu_trace.h"]:
        p=root/rel
        if p.exists(): gpu_raw += "\n"+p.read_text(encoding="utf-8",errors="replace")
    gpu=strip_cpp_comments_and_strings(gpu_raw)
    req={
        "query_pool_creation":[r"createQueryPool",r"CreateQueryPool"],
        "write_timestamp2":[r"writeTimestamp2",r"vkCmdWriteTimestamp2"],
        "query_result_read":[r"getQueryPoolResults",r"vkGetQueryPoolResults"],
        "with_availability":[r"WithAvailability",r"WITH_AVAILABILITY"],
        "result_64":[r"QueryResultFlagBits::e64",r"QUERY_RESULT_64_BIT"],
        "timestamp_period":[r"timestampPeriod"],
        "valid_bits":[r"timestampValidBits"],
        "submit_identity":[r"submit_id"],
        "queue_identity":[r"queue_id"],
        "cmdbuf_identity":[r"command_buffer_id"],
        "gpu_tick_identity":[r"\btick\b"],
    }
    for label,pats in req.items():
        ok=any(re.search(x,gpu,re.I) for x in pats)
        checks.append(Check("GPU_QUERY_LIFECYCLE:"+label,ok," | ".join(pats)))
    bad=bool(re.search(r"QueryResultFlagBits::eWait|QUERY_RESULT_WAIT_BIT|\bwaitIdle\s*\(",gpu,re.I))
    checks.append(Check("GPU_QUERY_LIFECYCLE:no_wait_bit_or_waitidle",not bad,
                        "comments/strings stripped before checking"))
    loss=bool(re.search(
        r"(query|gpu)[A-Za-z0-9_]*(lost|drop)|(lost|drop)[A-Za-z0-9_]*(query|gpu)|"
        r"GpuQueryExhausted|GpuTimestampBudget|GpuQueryReadError|GpuQueryUnresolvedOnShutdown",
        gpu,re.I))
    checks.append(Check("GPU_QUERY_LIFECYCLE:loss_accounting",loss,
                        "query exhaustion must be explicitly accounted"))

    sched=root/"src/video_core/renderer_vulkan/vk_scheduler.cpp"
    if sched.exists():
        st=sched.read_text(encoding="utf-8",errors="replace")
        body=function_body(st,r"Scheduler::Scheduler\s*\(")
        ok=body is not None and ("bb_gpu" in body.lower() or "blackbox" in body.lower())
        checks.append(Check("SCHEDULER_BODY_PLACEMENT",ok,
                            "Blackbox init must be inside constructor body, not initializer expression"))
    else:
        checks.append(Check("SCHEDULER_BODY_PLACEMENT",False,"vk_scheduler.cpp missing"))

    dupes=[]
    if (root/"src").exists():
        defs={}
        for p in (root/"src").rglob("*.cpp"):
            code=strip_cpp_comments_and_strings(p.read_text(encoding="utf-8",errors="replace"))
            for m in re.finditer(r"\b(?:auto|const\s+auto|CpuScope|Bb\w+)\s+(bbx_scope_[A-Za-z0-9_]+)\b",code):
                defs.setdefault(m.group(1),[]).append(str(p.relative_to(root)))
        dupes=[(k,v) for k,v in defs.items() if len(v)>1]
    checks.append(Check("NO_DUPLICATE_BBX_SCOPE_DEFINITIONS",not dupes,f"duplicates={dupes!r}"))

    report={"gate":"BLACKBOX_V1_CI_CLEAN1","root":str(root),
            "pass":all(c.ok for c in checks),"checks":[asdict(c) for c in checks]}
    out=json.dumps(report,indent=2)
    print(out)
    if a.json:
        a.json.parent.mkdir(parents=True,exist_ok=True)
        a.json.write_text(out+"\n",encoding="utf-8")
    return 0 if report["pass"] else 2

if __name__=="__main__":
    raise SystemExit(main())
