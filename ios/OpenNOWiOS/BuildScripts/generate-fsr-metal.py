#!/usr/bin/env python3
"""Translate AMD's MIT FP32 EASU/RCAS implementation to MSL, retaining the math."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1] / 'OpenNOWiOS' / 'StreamVideo'
header = (root / 'ffx_fsr1.h').read_text()
easu = header[header.index(' void FsrEasuTapF('):header.index('\n#endif', header.index(' void FsrEasuTapF('))]
rcas = header[header.index(' void FsrRcasF('):header.index('\n#endif\n', header.index(' void FsrRcasF('))]
# Evaluate optional RCAS preprocessor branches: alpha always opaque, denoise enabled.
lines = []
active = [True]
for line in rcas.splitlines():
    stripped = line.strip()
    if stripped.startswith('#ifdef'):
        active.append(active[-1] and 'FSR_RCAS_DENOISE' in stripped)
    elif stripped == '#else':
        active[-1] = active[-2] and not active[-1]
    elif stripped == '#endif':
        active.pop()
    elif active[-1]:
        lines.append(line)
rcas = '\n'.join(lines)
text = easu + '\n' + rcas
text = re.sub(r'\b(?:inout|out) (AF[1234]) (\w+)', r'thread \1& \2', text)
types = {'AF1':'float','AF2':'float2','AF3':'float3','AF4':'float4','AU2':'uint2','AU4':'uint4','ASU2':'int2','AP1':'bool'}
for src, dst in types.items():
    text = text.replace(src + '_(', dst + '(')
    text = re.sub(r'\b' + src + r'\b', dst, text)
preamble = '''// Generated from AMD FidelityFX FSR1. See FSR-LICENSE.txt and ffx_fsr1.h.
#include <metal_stdlib>
using namespace metal;
float ARcpF1(float x) { return fabs(x) < 1e-8f ? 0.0f : 1.0f/x; }
float APrxLoRcpF1(float x) { return ARcpF1(x); }
float APrxMedRcpF1(float x) { return ARcpF1(x); }
float APrxLoRsqF1(float x) { return rsqrt(max(x, 1e-8f)); }
float ASatF1(float x) { return clamp(x,0.0f,1.0f); }
float AMin3F1(float a,float b,float c) { return min(a,min(b,c)); }
float AMax3F1(float a,float b,float c) { return max(a,max(b,c)); }
float3 AMin3F3(float3 a,float3 b,float3 c) { return min(a,min(b,c)); }
float3 AMax3F3(float3 a,float3 b,float3 c) { return max(a,max(b,c)); }
float2 AF2_AU2(uint2 x) { return as_type<float2>(x); }
float AF1_AU1(uint x) { return as_type<float>(x); }
#define FSR_RCAS_LIMIT (0.25f-(1.0f/16.0f))
struct FSR {
 texture2d<float,access::read> src;
 float4 load(int2 p) { return src.read(uint2(clamp(p,int2(0),int2(src.get_width()-1,src.get_height()-1)))); }
 float4 gather(float2 p,uint channel) {
  int2 base=int2(floor(p*float2(src.get_width(),src.get_height())-0.5f));
  return float4(load(base+int2(0,1))[channel],load(base+int2(1,1))[channel],load(base+int2(1,0))[channel],load(base)[channel]);
 }
 float4 FsrEasuRF(float2 p) { return gather(p,0); }
 float4 FsrEasuGF(float2 p) { return gather(p,1); }
 float4 FsrEasuBF(float2 p) { return gather(p,2); }
 float4 FsrRcasLoadF(int2 p) { return load(p); }
 void FsrRcasInputF(thread float& r,thread float& g,thread float& b) {}
'''
suffix = '''
};
kernel void fsrEasu(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
 if(any(p>=uint2(dst.get_width(),dst.get_height()))) return;
 float2 inv=1.0f/float2(src.get_width(),src.get_height());
 float2 scale=float2(src.get_width(),src.get_height())/float2(dst.get_width(),dst.get_height());
 uint4 c0=as_type<uint4>(float4(scale,0.5f*scale-0.5f));
 uint4 c1=as_type<uint4>(float4(inv,inv*float2(1,-1)));
 uint4 c2=as_type<uint4>(float4(inv*float2(-1,2),inv*float2(1,2)));
 uint4 c3=as_type<uint4>(float4(inv*float2(0,4),0,0));
 FSR f={src}; float3 rgb; f.FsrEasuF(rgb,p,c0,c1,c2,c3);
 dst.write(float4(clamp(rgb,0.0f,1.0f),1),p);
}
kernel void fsrRcas(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], constant float& sharpness [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
 if(any(p>=uint2(dst.get_width(),dst.get_height()))) return;
 FSR f={src}; float3 rgb; uint4 c=uint4(as_type<uint>(exp2(-2.0f*(1.0f-sharpness))),0,0,0);
 float r,g,b; f.FsrRcasF(r,g,b,p,c); rgb=float3(r,g,b);
 dst.write(float4(clamp(rgb,0.0f,1.0f),1),p);
}
'''
(root / 'FSR1.metal').write_text(preamble + text + suffix)
