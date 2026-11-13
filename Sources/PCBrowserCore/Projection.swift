import Foundation

public enum ProjectionMode: String, CaseIterable, Sendable, Codable {
    case raw, perspective, panorama, frontRear, quad, dome, ring, globe, grid16
    public var label: String {
        switch self {
        case .raw:return "魚眼（元映像）";case .perspective:return "フラット / VR";case .panorama:return "360°パノラマ"
        case .frontRear:return "前後2画面";case .quad:return "4分割";case .dome:return "ドーム";case .ring:return "リング";case .globe:return "全球";case .grid16:return "16分割"
        }
    }
    public var shaderID: Int { Self.allCases.firstIndex(of:self)! }
    public var aspect: Double { switch self {case .raw:return 2560.0/1080;case .panorama:return 2;case .frontRear:return 32.0/9;case .dome,.ring,.globe:return 1;default:return 16.0/9} }
}
public struct ProjectionSettings: Sendable, Codable, Equatable {
    public var mode: ProjectionMode = .raw
    public var yaw = 0.0, pitch = 0.0, roll = 0.0, fieldOfView = 100.0
    public var lensFOV = 190.0, frontRotation = -90.0, rearRotation = -90.0
    public var radiusScale = 0.98, frontCenterX = 0.25, frontCenterY = 0.5, rearCenterX = 0.75, rearCenterY = 0.5
    public var night = false, exposure = 0.0, rawZoom = 1.0
    public init() {}
    public var clamped: ProjectionSettings {
        var s=self
        func clip(_ x:Double,_ lo:Double,_ hi:Double,_ fallback:Double)->Double { x.isFinite ? min(hi,max(lo,x)):fallback }
        s.yaw=clip(yaw,-180,180,0);s.pitch=clip(pitch,-89,89,0);s.roll=clip(roll,-180,180,0);s.fieldOfView=clip(fieldOfView,30,150,100)
        s.lensFOV=clip(lensFOV,180,220,190);s.frontRotation=clip(frontRotation,-180,180,-90);s.rearRotation=clip(rearRotation,-180,180,-90)
        s.radiusScale=clip(radiusScale,0.5,1.3,0.98);s.frontCenterX=clip(frontCenterX,0,0.5,0.25);s.rearCenterX=clip(rearCenterX,0.5,1,0.75)
        s.frontCenterY=clip(frontCenterY,0,1,0.5);s.rearCenterY=clip(rearCenterY,0,1,0.5)
        s.exposure=clip(exposure,-2,3,0);s.rawZoom=clip(rawZoom,1,4,1);return s
    }
}
public enum ProjectionMath {
    public static func perspectiveRay(u:Double,v:Double,aspect:Double,fov:Double,yaw:Double,pitch:Double) -> SIMD3<Double> {
        let t=tan(fov * .pi/360), p=SIMD3((2*u-1)*aspect*t,(1-2*v)*t,1.0)
        let n=p/sqrt(p.x*p.x+p.y*p.y+p.z*p.z), a=yaw * .pi/180,b=pitch * .pi/180
        let tilted=SIMD3(n.x,n.y*cos(b)+n.z*sin(b),-n.y*sin(b)+n.z*cos(b))
        return SIMD3(tilted.x*cos(a)+tilted.z*sin(a),tilted.y,-tilted.x*sin(a)+tilted.z*cos(a))
    }
    public static func sourceCoordinate(ray:SIMD3<Double>,width:Int,height:Int,settings:ProjectionSettings) -> SIMD2<Double>? {
        guard width>0,height>0 else {return nil};let s=settings.clamped
        let len=sqrt(ray.x*ray.x+ray.y*ray.y+ray.z*ray.z)
        guard len.isFinite,len>0 else{return nil};let n=ray/len,back=n.z<0
        let z=back ? -n.z:n.z, x=back ? -n.x:n.x, angle=acos(min(1,max(-1,z))),half=s.lensFOV * .pi/360
        guard angle<=half else{return nil}
        let a=(back ? s.rearRotation:s.frontRotation) * .pi/180, phi=atan2(-n.y,x)+a
        let radius=Double(height)*s.radiusScale/2*angle/half
        return SIMD2((back ? s.rearCenterX:s.frontCenterX)*Double(width)+radius*cos(phi),(back ? s.rearCenterY:s.frontCenterY)*Double(height)+radius*sin(phi))
    }
}
