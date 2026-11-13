import SwiftUI
import AppKit
import MapKit
import Charts
import PCBrowserCore

struct RouteMap: NSViewRepresentable {
    let points:[GeoCoordinate]
    let current:GeoCoordinate?
    let follow:Bool
    let satellite:Bool
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeNSView(context:Context)->MKMapView {
        let map=MKMapView();map.delegate=context.coordinator;map.showsCompass=true;map.showsScale=true;map.showsUserLocation=false;map.isRotateEnabled=true
        return map
    }
    func updateNSView(_ map:MKMapView,context:Context) {
        map.mapType=satellite ? .hybrid:.standard
        let c=context.coordinator,key="\(points.count)-\(points.first?.latitude ?? 0)-\(points.last?.longitude ?? 0)"
        if c.routeKey != key {
            c.routeKey=key;map.removeOverlays(map.overlays)
            if !points.isEmpty {
                let coords=points.map{CLLocationCoordinate2D(latitude:$0.latitude,longitude:$0.longitude)},line=MKPolyline(coordinates:coords,count:coords.count)
                map.addOverlay(line)
                if points.count>1 {map.setVisibleMapRect(line.boundingMapRect,edgePadding:NSEdgeInsets(top:35,left:35,bottom:35,right:35),animated:false)}
                else if let p=coords.first{map.setRegion(MKCoordinateRegion(center:p,latitudinalMeters:1500,longitudinalMeters:1500),animated:false)}
            }
        }
        if let p=current,p.valid {
            let location=CLLocationCoordinate2D(latitude:p.latitude,longitude:p.longitude)
            if c.pin==nil {let pin=MKPointAnnotation();pin.title="再生位置";map.addAnnotation(pin);c.pin=pin}
            c.pin?.coordinate=location
            if follow && !map.visibleMapRect.insetBy(dx:map.visibleMapRect.width*0.18,dy:map.visibleMapRect.height*0.18).contains(MKMapPoint(location)){map.setCenter(location,animated:false)}
        }else if let pin=c.pin{map.removeAnnotation(pin);c.pin=nil}
    }
    final class Coordinator:NSObject,MKMapViewDelegate {
        var routeKey="",pin:MKPointAnnotation?
        func mapView(_ mapView:MKMapView,rendererFor overlay:MKOverlay)->MKOverlayRenderer {
            if let line=overlay as? MKPolyline{let r=MKPolylineRenderer(polyline:line);r.strokeColor = .systemBlue;r.lineWidth=3;return r};return MKOverlayRenderer(overlay:overlay)
        }
    }
}
struct SensorSample:Identifiable,Sendable {
    let id:String,time:Double,axis:String,kind:String,value:Double
    static func make(_ r:Recording,timeline:RecordingTimeline)->[SensorSample] {
        let step=max(1,r.packets.count/500);var out:[SensorSample]=[]
        for i in stride(from:0,to:r.packets.count,by:step) {
            let p=r.packets[i]
            for (kind,values) in [("加速度",p.telemetry.accelerationRaw),("ジャイロ",p.telemetry.gyroRaw)] {
                for j in 0..<min(3,values.count){let axis=["X","Y","Z"][j];out.append(.init(id:"\(kind)-\(i)-\(j)",time:timeline.starts[i],axis:axis,kind:kind,value:Double(values[j])))}
            }
        };return out
    }
}
struct SensorPanel:View {
    @ObservedObject var model:BrowserModel
    @State private var kind="加速度"
    private var isAcceleration:Bool {kind=="加速度"}
    private var factor:Double? {isAcceleration ? model.sensorCalibration.accelerationCountsPerUnit:model.sensorCalibration.gyroCountsPerUnit}
    private var calibrated:Bool {if let factor,factor.isFinite,factor>0{return true};return false}
    private func shown(_ raw:Double)->Double {if calibrated,let factor{return raw/factor};return raw}
    private var rows:[SensorSample] {model.sensors.filter{$0.kind==kind}}
    private var yDomain:ClosedRange<Double> {
        if calibrated {let full=isAcceleration ? model.sensorScale.accelerationFullScale:model.sensorScale.gyroFullScale;return -full...full}
        let values=rows.map{$0.value};let low=min(values.min() ?? -1,-1),high=max(values.max() ?? 1,1);return low...high
    }
    private var tickValues:[Double] {
        if calibrated {return isAcceleration ? model.sensorScale.accelerationTickValues:model.sensorScale.gyroTickValues}
        let range=yDomain;return [range.upperBound,range.upperBound/2,0,range.lowerBound/2,range.lowerBound]
    }
    private func tickLabel(_ value:Double)->String {calibrated && isAcceleration ? String(format:"%.1f",value):String(format:"%.0f",value)}
    private var note:String {
        var text=calibrated ? "利用者入力の換算係数 · 目盛りは原版の「\(model.sensorScale.label)」":"raw counts · 原版の換算係数は未確定（設定▸音声・GPSで任意入力）"
        if let legacy=model.legacyModel,legacy.sensorPanelClass==0 {text+=" · 選択機種の原版はセンサーパネルを描画しません"}
        return text
    }
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {Picker("センサー",selection:$kind){Text("加速度").tag("加速度");Text("ジャイロ").tag("ジャイロ")}.pickerStyle(.segmented).frame(width:200);Spacer();Text(note).font(.caption).foregroundStyle(.secondary)}
            Chart {
                ForEach(rows){sample in LineMark(x:.value("録画内の秒",sample.time),y:.value("値",shown(sample.value))).foregroundStyle(by:.value("軸",sample.axis)).lineStyle(StrokeStyle(lineWidth:1.4))}
                RuleMark(x:.value("現在",model.currentSeconds)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth:1,dash:[4]))
            }.chartForegroundStyleScale(["X":Color.orange,"Y":Color.green,"Z":Color.blue]).chartXAxisLabel("録画内の秒").chartYAxisLabel(calibrated ? "換算値":"raw").chartYScale(domain:yDomain)
            .chartYAxis {AxisMarks(values:tickValues){value in AxisGridLine();AxisTick();AxisValueLabel{Text(tickLabel(value.as(Double.self) ?? 0))}}}
            .frame(minHeight:120)
        }.padding(10)
    }
}
