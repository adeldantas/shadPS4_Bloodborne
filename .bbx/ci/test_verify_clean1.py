#!/usr/bin/env python3
import tempfile,subprocess,sys,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
VERIFY=HERE/"verify_clean1.py"
def w(root,rel,text):
    p=root/rel; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(text,encoding="utf-8")
def make(root):
    for rel in ["src/common/bb_blackbox/schema.h","src/common/bb_blackbox/recorder.h",
                "src/common/bb_blackbox/recorder.cpp","src/common/bb_blackbox/sites.h",
                "src/common/bb_blackbox/identity.cpp","tools/bb_blackbox/decode.py"]:
        w(root,rel,"// clean1\n")
    w(root,"src/video_core/renderer_vulkan/bb_uma_policy.h",
      'inline constexpr auto CoreVerdict="C_WRITEBACK_UNSAFE";\n'
      'inline constexpr bool GcWritebackEnabled=false;\n'
      'inline constexpr bool BufferGcEnabled=false;\n'
      'inline constexpr bool DiscardStaleEnabled=false;\n')
    w(root,"src/core/file_sys/backends/host_fs.cpp","auto x=Common::FS::FileShareFlag::ShareReadWrite;\n")
    w(root,"src/video_core/renderer_vulkan/bb_gpu_trace.h",
      "struct Meta{unsigned queue_id,scheduler_id,command_buffer_id,submit_id; unsigned long long tick;};\n")
    w(root,"src/video_core/renderer_vulkan/bb_gpu_trace.cpp",
      "void f(){createQueryPool();cmdbuf.writeTimestamp2();getQueryPoolResults();"
      "auto a=QueryResultFlagBits::e64;auto b=QueryResultFlagBits::eWithAvailability;"
      "auto timestampPeriod=1;auto timestampValidBits=64;unsigned submit_id=0,queue_id=0,command_buffer_id=0;"
      "unsigned long long tick=0;int query_lost_count=0;query_lost_count++;}\n")
    w(root,"src/video_core/renderer_vulkan/vk_scheduler.cpp",
      "Scheduler::Scheduler(const Instance& instance):instance{instance},master_semaphore{instance},"
      "command_pool{instance,&master_semaphore}{bb_gpu_trace.Initialize();}\n"
      "void Scheduler::SubmitExecution(SubmitInfo& info){}\nvoid Scheduler::Finish(){}\nvoid Scheduler::Wait(u64 tick){}\n")
    w(root,"src/video_core/buffer_cache/buffer_cache.cpp",
      "void BufferCache::SynchronizeBuffer(){}\nvoid BufferCache::SynchronizeBufferFromImage(){}\n")
    w(root,"src/video_core/renderer_vulkan/vk_rasterizer.cpp",
      "void Rasterizer::Draw(){}\nvoid Rasterizer::DrawIndirect(){}\n")
    w(root,"src/video_core/texture_cache/texture_cache.cpp",
      "void TextureCache::InvalidateMemory(){}\nvoid TextureCache::InvalidateMemoryFromGPU(){}\n")
def run(root):
    p=subprocess.run([sys.executable,str(VERIFY),str(root)],capture_output=True,text=True)
    return p.returncode,json.loads(p.stdout)
with tempfile.TemporaryDirectory() as td:
    r=Path(td); make(r); rc,rep=run(r); assert rc==0,rep
    p=r/"src/video_core/buffer_cache/buffer_cache.cpp"
    p.write_text(p.read_text()+"\nvoid BufferCache::SynchronizeBuffer(){}\n")
    rc,rep=run(r); assert rc!=0
    assert any((not c["ok"]) and "SynchronizeBuffer" in c["name"] for c in rep["checks"])
print("verify_clean1 regression tests: PASS")
