import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import PCBrowserCore

@MainActor final class BrowserModel: ObservableObject {
    @Published var index:ImageIndex?
    @Published var selectedID:String? { didSet {if oldValue != selectedID {prepareSelection()}} }
    @Published var image:NSImage?
    @Published var frameIndex=0
    @Published var scrubber=0.0
    @Published var playing=false
    @Published var scanning=false
    @Published var rendering=false
    @Published var busy=false
    @Published var progress=0.0
    @Published var status="IMGファイルまたはSDカードを選択してください"
    @Published var sourceName="未選択"
    @Published var cardNotice=""
    @Published var errorMessage:String?
    @Published var playbackFPS=30.0
    @Published var playbackRate=1.0 {didSet {if oldValue != playbackRate {pause()}}}
    @Published var reverse=false
    @Published var volume=0.8 {didSet {audioPlayer?.volume=muted ? 0:Float(volume)}}
    @Published var muted=false {didSet {audioPlayer?.volume=muted ? 0:Float(volume)}}
    @Published var audioStatus="音声なし"
    @Published var audioDuration=0.0
    @Published var audioDrift=0.0
    @Published var projection=ProjectionSettings() {didSet {if oldValue != projection {saveViewerPreferences();reproject()}}}
    @Published var datum=GPSDatum.deviceTokyo {didSet {updateRoute();saveViewerPreferences()}}
    @Published var showMap=true
    @Published var followMap=true
    @Published var satelliteMap=false
    @Published var search=""
    @Published var filter="すべて"
    @Published var descending=false
    @Published var minSpeed=""
    @Published var selectedExports=Set<String>()
    @Published var bookmarks=Set<String>()
    @Published var inFrame=0
    @Published var outFrame=0
    @Published var useRange=false
    @Published var exportSubtitles=true
    @Published var showSettings=false
    @Published var showCapabilities=false
    @Published var cardFiles:[CardFile]=[]
    @Published var route:[GeoCoordinate]=[]
    @Published var sensors:[SensorSample]=[]
    private(set) var source:(any ByteSource)?
    private(set) var sourceURL:URL?
    private(set) var displayedFrame:CGImage?
    private(set) var rawFrame:CGImage?
    private(set) var timeline=RecordingTimeline(packets:[])
    private(set) var audioClip:AudioClip?
    private var audioPlayer:AVAudioPlayer?
    private var renderer:FrameRenderer?
    private let projector=PreviewProjector()
    private var cancellation=ScanCancellation(),exportCancellation=ScanCancellation()
    private var generation=UUID(),selectionGeneration=UUID(),playGeneration=UUID(),rawGeneration=UUID(),renderRequest=0
    private var playTask:Task<Void,Never>?,audioTask:Task<Void,Never>?,projectionTask:Task<Void,Never>?
    private var notifications:[NSObjectProtocol]=[]
    private var bookmarkKey="pcbrowser.bookmarks"
    var recording:Recording? {index?.recordings.first{$0.id==selectedID}}
    var packet:FramePacket? {guard let r=recording,r.packets.indices.contains(frameIndex) else{return nil};return r.packets[frameIndex]}
    var coordinate:GeoCoordinate? {packet?.telemetry.coordinate(datum:datum)}
    var currentSeconds:Double {timeline.starts.indices.contains(frameIndex) ? timeline.starts[frameIndex]:0}
    var activeAudioClockSeconds:Double? {
        guard let player=audioPlayer,player.isPlaying else{return nil}
        return player.currentTime
    }
    var selectedRecordings:[Recording] {if selectedExports.isEmpty{return recording.map{[$0]} ?? []};return index?.recordings.filter{selectedExports.contains($0.id)} ?? []}
    var exportFrames:Range<Int> {guard let r=recording,!r.packets.isEmpty else{return 0..<0};return useRange ? max(0,min(inFrame,outFrame))..<min(r.packets.count,max(inFrame,outFrame)+1):0..<r.packets.count}
    var filteredRecordings:[Recording] {
        let s=search.trimmingCharacters(in:.whitespacesAndNewlines),threshold=Double(minSpeed)
        var rows=(index?.recordings ?? []).filter {r in
            if !s.isEmpty && !(r.startTime+" "+r.endTime+" "+r.id+" CH\(r.channel)").localizedCaseInsensitiveContains(s){return false}
            if filter=="しおり" && !bookmarks.contains(r.id){return false}
            if filter=="GPSあり" && !r.packets.contains(where:{$0.telemetry.coordinate(datum:datum) != nil}){return false}
            if filter=="音声あり" && !r.packets.contains(where:{$0.auxiliaryBytes>0}){return false}
            if let threshold,threshold.isFinite,!r.packets.contains(where:{($0.telemetry.speedKMH ?? -1)>=threshold}){return false}
            return true
        }
        if descending {rows.reverse()};return rows
    }
    init() {
        if let d=UserDefaults.standard.data(forKey:"pcbrowser.projection"),let p=try? JSONDecoder().decode(ProjectionSettings.self,from:d){projection=p.clamped}
        if let s=UserDefaults.standard.string(forKey:"pcbrowser.gpsdatum"),let d=GPSDatum(rawValue:s){datum=d}
        for name in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification] {
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.cardNotice="外部メディアの接続状態が変わりました。SDカードを選択できます"}})
        }
    }
    private func saveViewerPreferences() {if let d=try? JSONEncoder().encode(projection.clamped){UserDefaults.standard.set(d,forKey:"pcbrowser.projection")};UserDefaults.standard.set(datum.rawValue,forKey:"pcbrowser.gpsdatum")}
    func openPanel() {
        let p=NSOpenPanel();p.title="SDカードのIMGまたは.pcbbackupを開く";p.canChooseDirectories=true;p.canChooseFiles=true;p.allowsMultipleSelection=false
        if p.runModal() == .OK,let u=p.url{open(u)}
    }
    func open(_ url:URL,limit:UInt64?=nil) {
        cancel();generation=UUID();let token=generation;scanning=true;status="入力を読み取り専用で開いています…";errorMessage=nil
        Task {
            do {let source=try await Task.detached{try SourceOpener.open(url)}.value;guard generation==token else{return};sourceURL=url
                bookmarkKey="pcbrowser.bookmarks."+url.standardizedFileURL.path;bookmarks=Set(UserDefaults.standard.stringArray(forKey:bookmarkKey) ?? [])
                load(source,name:url.lastPathComponent,limit:limit)
            }catch{guard generation==token else{return};scanning=false;errorMessage=error.localizedDescription}
        }
    }
    func cancel() {cancellation.cancel();exportCancellation.cancel();pause()}
    private func load(_ source:any ByteSource,name:String,limit:UInt64?=nil) {
        cancel();generation=UUID();let token=generation,flag=ScanCancellation();cancellation=flag
        self.source=source;index=nil;selectedID=nil;image=nil;sourceName=name;progress=0;scanning=true;errorMessage=nil;selectedExports=[];cardFiles=[]
        status="録画領域を読み取り専用で走査しています…"
        Task {
            do {
                let result=try await Task.detached(priority:.userInitiated){try ImageScanner.scan(source,limitBytes:limit,cancelled:{flag.cancelled}){done,total,count in
                    Task{@MainActor [weak self] in guard let self,self.generation==token else{return};self.progress=total>0 ? Double(done)/Double(total):0;self.status="\(count)フレームを確認 · \(Int(self.progress*100))%"}
                }}.value
                guard generation==token else{return};index=result;scanning=false;progress=1
                status="\(result.recordings.count)件の録画 · \(result.frameCount)フレーム"+(result.isPartialScan ? "（部分コピー／一部走査）":"")
                if result.frameCount==0{status="対応する映像パケットが見つかりませんでした"}
                selectedID=result.recordings.first?.id
                let settings=try? await Task.detached{try CardSettingsReader.read(source)}.value
                if generation==token {cardFiles=settings ?? []}
            }catch{guard generation==token else{return};scanning=false;status=flag.cancelled ? "走査をキャンセルしました":"読み取りを完了できませんでした";if !flag.cancelled{errorMessage=error.localizedDescription}}
        }
    }
    private func prepareSelection() {
        pause();audioTask?.cancel();selectionGeneration=UUID();let token=selectionGeneration
        image=nil;displayedFrame=nil;rawFrame=nil;audioPlayer=nil;audioClip=nil;audioStatus="音声を読み取っています…";audioDuration=0;audioDrift=0;frameIndex=0;scrubber=0;rendering=false
        guard let r=recording,let source else {renderer=nil;route=[];sensors=[];return}
        renderer=FrameRenderer(source:source,packets:r.packets);timeline=RecordingTimeline(packets:r.packets);playbackFPS=timeline.nominalFPS
        inFrame=0;outFrame=max(0,r.packets.count-1);useRange=false;updateRoute();sensors=SensorSample.make(r,timeline:timeline)
        let first=r.packets.firstIndex(where:{$0.isIntra}) ?? 0;Task{await renderFrame(first)}
        audioTask=Task {
            do {
                let clip=try await Task.detached{guard r.packets.contains(where:{$0.auxiliaryBytes>0}) else{throw BrowserError.unsupported("音声データは記録されていません")};let format=try PCMFormat.recordFormat(source:source,recording:r);return try AudioClip.load(source:source,packets:r.packets,format:format)}.value
                guard selectionGeneration==token,!Task.isCancelled else{return}
                let player=try AVAudioPlayer(data:clip.wav());player.enableRate=true;player.volume=muted ? 0:Float(volume)
                guard player.prepareToPlay() else{throw BrowserError.io("macOSの音声再生を準備できません")}
                audioClip=clip;audioPlayer=player;audioDuration=clip.duration;audioDrift=clip.duration-timeline.duration
                audioStatus=clip.format.description+String(format:" · %.2f秒",clip.duration)
            }catch{guard selectionGeneration==token else{return};audioStatus="音声: "+error.localizedDescription}
        }
    }
    func updateRoute() {
        guard let r=recording else{route=[];return};var out:[GeoCoordinate]=[],last:GeoCoordinate?
        for p in r.packets {if let c=p.telemetry.coordinate(datum:datum),c != last {out.append(c);last=c}}
        if out.count>20000 {let step=max(1,out.count/20000);route=out.enumerated().compactMap{$0.offset%step==0 ? $0.element:nil}}else{route=out}
    }
    func renderFrame(_ position:Int) async {
        guard let renderer,let r=recording,r.packets.indices.contains(position) else{return}
        renderRequest+=1;let request=renderRequest,selection=selectionGeneration;rendering=true
        do {
            let raw=try await renderer.render(position),settings=projection
            let frame=try await projector.render(raw,settings:settings)
            guard selectionGeneration==selection,request==renderRequest,!Task.isCancelled else{return}
            projectionTask?.cancel();rawGeneration=UUID();rawFrame=raw;displayedFrame=frame;image=NSImage(cgImage:frame,size:NSSize(width:frame.width,height:frame.height));frameIndex=position;scrubber=Double(position)
            if settings != projection {reproject()}
        }catch{if selectionGeneration==selection,request==renderRequest,!Task.isCancelled{pause();errorMessage=error.localizedDescription}}
        if request==renderRequest{rendering=false}
    }
    func reproject() {
        projectionTask?.cancel();guard let raw=rawFrame else{return};let settings=projection,selection=selectionGeneration,rawToken=rawGeneration
        projectionTask=Task {
            do {let image=try await projector.render(raw,settings:settings);guard !Task.isCancelled,selectionGeneration==selection,rawGeneration==rawToken else{return};displayedFrame=image;self.image=NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))}
            catch{if !Task.isCancelled{errorMessage=error.localizedDescription}}
        }
    }
    func seek(){pause();let position=Int(scrubber.rounded());Task{await renderFrame(position)}}
    func step(_ delta:Int){pause();guard let r=recording,!r.packets.isEmpty else{return};let target=max(0,min(r.packets.count-1,frameIndex+delta));Task{await renderFrame(target)}}
    func pause(){playGeneration=UUID();playing=false;playTask?.cancel();playTask=nil;audioPlayer?.pause();renderRequest+=1;rendering=false}
    func togglePlay(backwards:Bool?=nil) {
        if playing,backwards==nil || backwards==reverse{pause();return};pause();if let backwards{reverse=backwards}
        guard let r=recording,!r.packets.isEmpty else{return};playing=true;let selection=selectionGeneration,playToken=playGeneration
        playTask=Task{[weak self] in
            guard let self else{return};await audioTask?.value
            guard playing,!Task.isCancelled,selectionGeneration==selection,playGeneration==playToken else{return}
            if !reverse && frameIndex==r.packets.count-1{await renderFrame(0)}
            if reverse && frameIndex==0{await renderFrame(r.packets.count-1)}
            let base=currentSeconds,began=ProcessInfo.processInfo.systemUptime,rate=playbackRate,direction=reverse ? -1.0:1.0
            var soundClock=false
            if !reverse,(0.5...2).contains(rate),let player=audioPlayer,base<player.duration {player.currentTime=base;player.rate=Float(rate);soundClock=player.play()}
            while !Task.isCancelled,playing,selectionGeneration==selection,playGeneration==playToken {
                let elapsed=ProcessInfo.processInfo.systemUptime-began
                if soundClock,let player=audioPlayer,!player.isPlaying,elapsed>0.1 {break}
                let position=soundClock ? (audioPlayer?.currentTime ?? base):base+elapsed*rate*direction
                if (!reverse && position>=timeline.duration) || (reverse && position<=0){break}
                let target=timeline.frame(at:position)
                if target != frameIndex {await renderFrame(target)}else{try? await Task.sleep(nanoseconds:5_000_000)}
                if soundClock,let p=audioPlayer,!p.isPlaying,position>=p.duration-0.02 {break}
            }
            if selectionGeneration==selection,playGeneration==playToken {playing=false;audioPlayer?.pause()}
        }
    }
    func toggleBookmark(_ id:String){if bookmarks.contains(id){bookmarks.remove(id)}else{bookmarks.insert(id)};UserDefaults.standard.set(Array(bookmarks),forKey:bookmarkKey)}
    func seekByTime(){let a=NSAlert();a.messageText="録画内の秒数へ移動";let field=NSTextField(string: String(format:"%.2f",currentSeconds));field.frame=NSRect(x:0,y:0,width:240,height:24);a.accessoryView=field;a.addButton(withTitle:"移動");a.addButton(withTitle:"キャンセル");if a.runModal() == .alertFirstButtonReturn,let seconds=Double(field.stringValue),seconds.isFinite{pause();let frame=timeline.frame(at:seconds);Task{await renderFrame(frame)}}}
    func chooseSD() {
        pause();status="外部メディアの一覧を確認しています…"
        Task {
            do {
                let disks=try await Task.detached{try SDCardAccess.list()}.value
                guard !disks.isEmpty else{throw BrowserError.io("外部の物理ディスクが見つかりません。SDカードとカードリーダーを確認してください")}
                let alert=NSAlert();alert.messageText="読み取るSDカードを選択";alert.informativeText="外部の物理ディスクをO_RDONLYで開きます。消去・設定変更・マウント解除は行いません。"
                let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28));popup.addItems(withTitles:disks.map{"\($0.name) — \($0.bsd) — \(ByteCountFormatter.string(fromByteCount:Int64($0.bytes),countStyle:.file))"});alert.accessoryView=popup;alert.addButton(withTitle:"読み取り専用で開く");alert.addButton(withTitle:"キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else{status="SDカードの選択をキャンセルしました";return}
                guard let helper=Bundle.main.url(forAuxiliaryExecutable:"PCBrowserRawReader") else{throw BrowserError.io("SDカード用ヘルパーがありません。.appから起動してください")}
                let disk=disks[popup.indexOfSelectedItem];status="SDカードの読み取り許可を待っています…"
                let s=try await Task.detached{try SDCardAccess.open(disk,helper:helper)}.value;sourceURL=nil;bookmarkKey="pcbrowser.bookmarks.disk."+disk.bsd;bookmarks=Set(UserDefaults.standard.stringArray(forKey:bookmarkKey) ?? []);cardNotice="";load(s,name:"\(disk.name) / \(disk.bsd)")
            }catch{errorMessage=error.localizedDescription;status="SDカードを開けませんでした"}
        }
    }
    func performExport(_ title:String,operation:@escaping @Sendable (ScanCancellation,@escaping @Sendable (Double)->Void) async throws->Void) {
        guard !busy else{return};pause();busy=true;progress=0;status=title+"…";let flag=ScanCancellation();exportCancellation=flag
        Task{
            do {try await Task.detached(priority:.userInitiated){try await operation(flag){fraction in Task{@MainActor [weak self] in self?.progress=fraction}}}.value;status=title+"が完了しました"}
            catch{status=flag.cancelled ? "書き出しをキャンセルしました":"書き出しを完了できませんでした";if !flag.cancelled{errorMessage=error.localizedDescription}}
            busy=false;progress=0
        }
    }
}
