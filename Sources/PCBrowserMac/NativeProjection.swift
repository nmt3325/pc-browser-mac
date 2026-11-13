import Foundation
import CoreGraphics
import Metal
import MetalKit
import PCBrowserCore

/// GPU reprojection with explicit, user-adjustable equidistant-lens geometry.
/// Manufacturer lens calibration is not available; this must not be called factory-corrected.
final class NativeProjection {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let loader: MTKTextureLoader
    init() throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw BrowserError.unsupported("Metal GPUが使用できません")}
        device=d;queue=q;loader=MTKTextureLoader(device:d)
        let lib=try d.makeLibrary(source:Self.shader,options:nil)
        guard let fn=lib.makeFunction(name:"project") else {throw BrowserError.io("360°補正シェーダーを作成できません")}
        pipeline=try d.makeComputePipelineState(function:fn)
    }
    /// Re-projects the frame, then applies the display flip / rotation / zoom state (right-click menu) with CoreGraphics.
    func render(_ image: CGImage, settings: ProjectionSettings, width requested: Int = 1280) throws -> CGImage {
        let s=settings.clamped
        let projected=try project(image,settings:s,width:requested)
        return s.view.isIdentity ? projected:(ViewTransformRenderer.apply(projected,s.view) ?? projected)
    }
    private func project(_ image: CGImage, settings s: ProjectionSettings, width requested: Int) throws -> CGImage {
        if s.mode == .raw && s.roll == 0 && s.rawZoom == 1 && !s.night && s.exposure == 0 {return image}
        let aspect=s.mode == .raw ? Double(image.width)/Double(image.height):s.mode.aspect
        // A zoomed view crops the result, so render wider to keep it sharp (capped at 4096).
        let w=max(64,min(4096,Int(Double(requested)*min(4,s.view.zoom)))), h=max(64,Int(Double(w)/aspect)/2*2)
        let input=try loader.newTexture(cgImage:image,options:[.SRGB:false,.origin:MTKTextureLoader.Origin.topLeft])
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:w,height:h,mipmapped:false)
        desc.usage=[.shaderWrite,.shaderRead];desc.storageMode = .shared
        guard let output=device.makeTexture(descriptor:desc),let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else {throw BrowserError.io("360°補正バッファーを作成できません")}
        let radians=Float.pi/180
        var uniforms:[SIMD4<Float>]=[
            SIMD4(Float(s.yaw)*radians,Float(s.pitch)*radians,Float(s.roll)*radians,Float(s.fieldOfView)*radians),
            SIMD4(Float(s.lensFOV)*radians,Float(s.frontRotation)*radians,Float(s.rearRotation)*radians,Float(s.radiusScale)),
            SIMD4(Float(s.frontCenterX),Float(s.frontCenterY),Float(s.rearCenterX),Float(s.rearCenterY)),
            SIMD4(Float(s.mode.shaderID),s.night ? 1:0,Float(s.exposure),Float(s.rawZoom))]
        encoder.setComputePipelineState(pipeline);encoder.setTexture(input,index:0);encoder.setTexture(output,index:1)
        uniforms.withUnsafeMutableBufferPointer { encoder.setBytes($0.baseAddress!,length:$0.count*MemoryLayout<SIMD4<Float>>.stride,index:0) }
        let tw=pipeline.threadExecutionWidth, th=max(1,pipeline.maxTotalThreadsPerThreadgroup/tw)
        encoder.dispatchThreads(MTLSize(width:w,height:h,depth:1),threadsPerThreadgroup:MTLSize(width:tw,height:th,depth:1));encoder.endEncoding()
        command.commit();command.waitUntilCompleted()
        if let error=command.error {throw error}
        var pixels=Data(count:w*h*4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
        guard let provider=CGDataProvider(data:pixels as CFData),let cg=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw BrowserError.io("360°補正映像を取得できません")}
        return cg
    }
    private static let shader = #"""
#include <metal_stdlib>
using namespace metal;
float3 orient(float3 d,float yaw,float pitch,float roll) {
    float3 p=float3(d.x,d.y*cos(pitch)+d.z*sin(pitch),-d.y*sin(pitch)+d.z*cos(pitch));
    p=float3(p.x*cos(yaw)+p.z*sin(yaw),p.y,-p.x*sin(yaw)+p.z*cos(yaw));
    return float3(p.x*cos(roll)-p.y*sin(roll),p.x*sin(roll)+p.y*cos(roll),p.z);
}
float2 lensUV(float3 d,bool rear,float2 inputSize,constant float4* p) {
    float z=rear ? -d.z:d.z,x=rear ? -d.x:d.x;
    float theta=acos(clamp(z,-1.0f,1.0f));
    float phi=atan2(-d.y,x)+(rear ? p[1].z:p[1].y);
    float r=inputSize.y*p[1].w*0.5f*theta/(p[1].x*0.5f);
    float2 center=rear ? p[2].zw:p[2].xy;
    return center+float2(r*cos(phi),r*sin(phi))/inputSize;
}
kernel void project(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],constant float4* p [[buffer(0)]],uint2 at [[thread_position_in_grid]]) {
    if(at.x>=out.get_width() || at.y>=out.get_height())return;
    constexpr sampler sample(filter::linear,address::clamp_to_zero);
    float2 uv=(float2(at)+0.5f)/float2(out.get_width(),out.get_height());
    int mode=int(p[3].x);float3 d;float4 col;float aspect=float(out.get_width())/out.get_height();float yaw=p[0].x;
    if(mode==0) {
        float2 t=(uv-0.5f)/p[3].w; t.x*=aspect;
        t=float2(t.x*cos(p[0].z)-t.y*sin(p[0].z),t.x*sin(p[0].z)+t.y*cos(p[0].z));t.x/=aspect;
        col=source.sample(sample,t+0.5f);
    } else {
        if(mode==2) {float lon=(uv.x*2-1)*M_PI_F,lat=(0.5f-uv.y)*M_PI_F;d=float3(sin(lon)*cos(lat),sin(lat),cos(lon)*cos(lat));}
        else if(mode==5 || mode==6 || mode==7) {
            float2 t=(uv-0.5f)*2;float r=length(t),phi=atan2(t.x,-t.y);
            if((mode==5 && r>1) || (mode==6 && (r<0.2f || r>1))) {out.write(float4(0,0,0,1),at);return;}
            if(mode==5)d=float3(t.x,sqrt(max(0.0f,1-r*r)),-t.y);
            else if(mode==6) {float lat=(0.6f-r)/0.4f*M_PI_F*0.5f;d=float3(sin(phi)*cos(lat),sin(lat),cos(phi)*cos(lat));}
            else {float theta=2*atan(r*2.0f);d=float3(sin(phi)*sin(theta),cos(theta),cos(phi)*sin(theta));}
        } else {
            float2 q=uv;
            if(mode==3) {yaw+=(uv.x>=0.5f ? M_PI_F:0);q.x=fract(uv.x*2);aspect/=2;}
            if(mode==4) {int n=int(uv.y*2)*2+int(uv.x*2);yaw+=float(n)*M_PI_F*0.5f;q=fract(uv*2);}
            if(mode==8) {int n=int(uv.y*4)*4+int(uv.x*4);yaw+=float(n)*M_PI_F/8;q=fract(uv*4);}
            float f=tan(p[0].w*0.5f);d=normalize(float3((q.x*2-1)*aspect*f,(1-q.y*2)*f,1));
        }
        d=orient(d,yaw,p[0].y,p[0].z);float2 size=float2(source.get_width(),source.get_height());
        col=source.sample(sample,lensUV(d,d.z<0,size,p));
        float overlap=max(0.0f,sin((p[1].x-M_PI_F)*0.5f));
        if(overlap>0.001f && abs(d.z)<overlap) {
            float4 front=source.sample(sample,lensUV(d,false,size,p)),rear=source.sample(sample,lensUV(d,true,size,p));
            col=mix(rear,front,smoothstep(-overlap,overlap,d.z));
        }
    }
    float3 rgb=clamp(col.rgb*exp2(p[3].z),0.0f,1.0f);
    if(p[3].y>0.5f)rgb=pow(rgb,float3(0.55f));
    out.write(float4(rgb,1),at);
}
"""#
}
actor PreviewProjector {
    private var projection: NativeProjection?
    func render(_ image:CGImage,settings:ProjectionSettings,width:Int=1280) throws -> CGImage {
        if projection == nil { projection=try NativeProjection() }
        return try projection!.render(image,settings:settings,width:width)
    }
}
