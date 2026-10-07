// Independent client interpolation. No PXPlay code or compiled shaders are used.
#include <metal_stdlib>
using namespace metal;
constexpr sampler videoSampler(coord::normalized,address::clamp_to_edge,filter::linear);
float videoLuma(texture2d<float> image,float2 pixel) {
 return dot(image.sample(videoSampler,(pixel+0.5f)/float2(image.get_width(),image.get_height())).rgb,float3(.2126,.7152,.0722));
}
// Coarse-to-fine block matching on an eighth-size motion field. Each output
// stores source-pixel displacement and residual; flat/cut regions use real frames.
kernel void videoFlow(texture2d<float> previous [[texture(0)]],texture2d<float> current [[texture(1)]],texture2d<float,access::write> flow [[texture(2)]],uint2 gid [[thread_position_in_grid]]) {
 if(any(gid>=uint2(flow.get_width(),flow.get_height()))) return;
 float2 center=(float2(gid)+0.5f)*8.0f-0.5f, displacement=0;
 float error=1e9f;
 for(int step=4;step>=1;step/=2) {
  float2 best=displacement; float bestError=1e9f;
  int range=step==4 ? 2 : 1;
  for(int y=-range;y<=range;y++) for(int x=-range;x<=range;x++) {
   float2 candidate=displacement+float2(x,y)*float(step);
   float score=0;
   for(int py=-1;py<=1;py++) for(int px=-1;px<=1;px++) {
    float2 p=center+float2(px,py)*4.0f;
    score+=fabs(videoLuma(previous,p)-videoLuma(current,p+candidate));
   }
   // A tiny displacement penalty breaks ties in static/flat regions.
   score=score/9.0f+dot(candidate,candidate)*1e-6f;
   if(score<bestError) { bestError=score;best=candidate; }
  }
  displacement=best; error=bestError;
 }
 flow.write(float4(displacement,error,1),gid);
}
kernel void videoWarp(texture2d<float> previous [[texture(0)]],texture2d<float> current [[texture(1)]],texture2d<float> flow [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],constant float& phase [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
 if(any(gid>=uint2(output.get_width(),output.get_height()))) return;
 float2 size=float2(output.get_width(),output.get_height()), uv=(float2(gid)+0.5f)/size;
 float4 motion=flow.sample(videoSampler,uv);
 float4 real=current.sample(videoSampler,uv);
 if(motion.z>.08f || phase>=1.0f) { output.write(float4(real.rgb,1),gid);return; }
 float3 a=previous.sample(videoSampler,uv-phase*motion.xy/size).rgb;
 float3 b=current.sample(videoSampler,uv+(1.0f-phase)*motion.xy/size).rgb;
 // Occlusion/cut rejection avoids blending unrelated content.
 float mismatch=dot(abs(a-b),float3(.2126,.7152,.0722));
 float3 rgb=mismatch>.12f ? real.rgb : mix(a,b,phase);
 output.write(float4(clamp(rgb,0.0f,1.0f),1),gid);
}
