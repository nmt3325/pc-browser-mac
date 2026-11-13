import SwiftUI
import AppKit
import PCBrowserCore

struct BrowserView: View {
    @ObservedObject var model:BrowserModel
    @State private var dragOrigin:Double?
    var body:some View {
        NavigationSplitView {sidebar.navigationSplitViewColumnWidth(min:245,ideal:280,max:350)} detail: {
            VStack(spacing:10) {
                if model.scanning || model.busy {HStack{ProgressView(value:model.progress);Text("\(Int(model.progress*100))%").monospacedDigit();Button("キャンセル",action:model.cancel)}.padding(.horizontal,2)}
                projectionBar
                HSplitView {
                    preview.frame(minWidth:440,minHeight:220)
                    if model.showMap {mapPanel.frame(minWidth:240,idealWidth:300,maxWidth:450,minHeight:220)}
                }.frame(maxHeight:.infinity)
                playbackControls
                TabView {
                    metadata.tabItem{Label("録画情報",systemImage:"info.circle")}
                    SensorPanel(model:model).tabItem{Label("センサー",systemImage:"waveform.path")}
                    exportRange.tabItem{Label("書き出し範囲",systemImage:"scissors")}
                }.frame(minHeight:165,idealHeight:195,maxHeight:230)
                HStack(alignment:.top) {Text(model.status).lineLimit(2);Spacer();if model.index?.isPartialScan==true {Text("部分コピー／一部走査").foregroundStyle(.orange)}}.font(.caption).foregroundStyle(.secondary)
                if !model.archiveNotice.isEmpty{Text(model.archiveNotice).font(.caption2).foregroundStyle(model.archiveNotice.contains("照合済み") ? Color.secondary:Color.orange)}
                if !model.cardNotice.isEmpty{Text(model.cardNotice).font(.caption).foregroundStyle(.blue)}
            }.padding(14).frame(minWidth:740,minHeight:650)
            .toolbar {
                ToolbarItemGroup {
                    Button(action:model.openPanel){Label("開く",systemImage:"doc.badge.plus")}.disabled(model.scanning || model.busy)
                    Button(action:model.chooseSD){Label("SDカード",systemImage:"sdcard")}.disabled(model.scanning || model.busy)
                    exportMenu.disabled(model.recording==nil || model.busy || model.scanning)
                    Button(action:model.recoveryScan){Label("復旧走査",systemImage:"externaldrive.badge.magnifyingglass")}.disabled(model.scanning || model.busy || model.source==nil).help("高速索引にない孤立データを全領域から探します（時間がかかります）")
                    Button{model.showSettings=true}label:{Label("設定",systemImage:"slider.horizontal.3")}
                    Button{model.showCapabilities=true}label:{Label("対応状況",systemImage:"questionmark.circle")}
                }
            }
        }
        .alert("確認が必要です",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage=nil}})){Button("閉じる",role:.cancel){model.errorMessage=nil}}message:{Text(model.errorMessage ?? "")}
        .sheet(isPresented:$model.showSettings){ViewerSettings(model:model)}
        .sheet(isPresented:$model.showCapabilities){CapabilitiesView()}
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:6){Label("PC Browser Mac",systemImage:"sdcard").font(.headline);Text(model.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(2)}.padding(14)
            TextField("日時・CH・録画IDで検索",text:$model.search).textFieldStyle(.roundedBorder).padding(.horizontal,10)
            HStack {Picker("表示",selection:$model.filter){ForEach(["すべて","GPSあり","音声あり","しおり"],id:\.self){Text($0)}}.labelsHidden();Button{model.descending.toggle()}label:{Image(systemName:model.descending ? "arrow.down":"arrow.up")}.help("日時の並び順")}.padding(10)
            HStack{Text("速度 ≥");TextField("km/h",text:$model.minSpeed).frame(width:70);Text("km/h")}.font(.caption).padding(.horizontal,12).padding(.bottom,8)
            if model.hasDetailFilter && model.hasUnsearchedDetails {
                VStack(alignment:.leading,spacing:4){Text("未確認の録画も表示中").font(.caption2).foregroundStyle(.secondary);Button("全録画の詳細検索",action:model.searchAllDetails).disabled(model.scanning || model.busy)}.padding(.horizontal,12).padding(.bottom,8)
            }
            Divider()
            List(selection:$model.selectedID) {
                ForEach(model.filteredRecordings){r in
                    HStack(spacing:7) {
                        Toggle("書き出し対象",isOn:Binding(get:{model.selectedExports.contains(r.id)},set:{on in if on{model.selectedExports.insert(r.id)}else{model.selectedExports.remove(r.id)}})).toggleStyle(.checkbox).labelsHidden().help("複数録画のバックアップ・ログ出力対象")
                        VStack(alignment:.leading,spacing:4){Text(r.startTime).font(.system(.caption,design:.monospaced));Text("CH/raw \(r.channel) · \(r.blockCount)ブロック · \(r.isLoaded ? "":"約")\(r.frameCount)枚").font(.caption2).foregroundStyle(.secondary)}
                        Spacer(minLength:0)
                        Button{model.toggleBookmark(r.id)}label:{Image(systemName:model.bookmarks.contains(r.id) ? "star.fill":"star").foregroundStyle(model.bookmarks.contains(r.id) ? .yellow:.secondary)}.buttonStyle(.borderless).help("しおり")
                    }.padding(.vertical,4).tag(r.id)
                }
            }
            .disabled(model.scanning || model.busy)
            Divider()
            HStack{Label("読み取り専用",systemImage:"lock.shield");Spacer();if !model.selectedExports.isEmpty{Text("\(model.selectedExports.count)件選択")}}.font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }
    private var projectionBar:some View {
        HStack(spacing:9) {
            Picker("表示",selection:$model.projection.mode){ForEach(ProjectionMode.allCases,id:\.self){Text($0.label).tag($0)}}.frame(width:205)
            if model.projection.mode != .raw {
                Text("方向").font(.caption);Slider(value:$model.projection.yaw,in:-180...180).frame(minWidth:60,maxWidth:120)
                Text("画角").font(.caption);Slider(value:$model.projection.fieldOfView,in:30...150).frame(minWidth:50,maxWidth:100)
            }
            Toggle("NIGHT",isOn:$model.projection.night).toggleStyle(.button)
            Button{model.projection.roll = model.projection.roll >= 90 ? -180:model.projection.roll+90}label:{Image(systemName:"rotate.right")}.help("90°回転")
            Spacer(minLength:0)
            Toggle(isOn:$model.showMap){Image(systemName:"map")}.toggleStyle(.button).help("地図の表示・非表示")
            Button(action:model.detachedPreview){Image(systemName:"macwindow.on.rectangle")}.help("映像を別ウインドウで表示")
        }.disabled(model.recording==nil)
    }
    private var preview:some View {
        ZStack {
            RoundedRectangle(cornerRadius:8).fill(.black)
            if let image=model.image {Image(nsImage:image).resizable().scaledToFit().padding(1).accessibilityLabel("録画映像プレビュー")}
            else{VStack(spacing:12){Image(systemName:"video").font(.system(size:40,weight:.light));Text(model.selectionLoading ? "選択した連続録画の索引を読み込み中":model.scanning ? "録画の索引を取得中":"SDカードの録画をMacで確認");Text("IMG / .pcbbackupを開くかSDカードを選択").font(.caption)}.foregroundStyle(.white.opacity(0.75))}
            if (model.rendering || model.selectionLoading) && !model.playing{ProgressView().controlSize(.large).padding(16).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10))}
            if model.projection.mode != .raw {VStack{Spacer();HStack{Text("標準魚眼モデル・手動校正").font(.caption2).padding(5).background(.black.opacity(0.5)).foregroundStyle(.white);Spacer()}}.padding(5)}
        }.gesture(DragGesture().onChanged{v in
            guard model.projection.mode != .raw else{return};if dragOrigin==nil{dragOrigin=model.projection.yaw};model.projection.yaw=max(-180,min(180,(dragOrigin ?? 0)+Double(v.translation.width)/3))
        }.onEnded{_ in dragOrigin=nil})
    }
    private var mapPanel:some View {
        VStack(spacing:6) {
            if model.route.isEmpty {VStack(spacing:10){Image(systemName:"location.slash").font(.largeTitle);Text("有効なGPS位置がありません").font(.caption);Button("外部NMEAログを開く",action:model.importNMEA)}}
            else {RouteMap(points:model.route,current:model.coordinate,follow:model.followMap,satellite:model.satelliteMap).clipShape(RoundedRectangle(cornerRadius:8))}
            HStack{Toggle("追従",isOn:$model.followMap);Toggle("航空写真",isOn:$model.satelliteMap)}.font(.caption)
            Text("地図タイルはインターネット接続が必要です").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var playbackControls:some View {
        VStack(spacing:8) {
            Slider(value:$model.scrubber,in:0...Double(max(1,(model.recording?.packets.count ?? 1)-1)),step:1){editing in if editing{model.pause()}else{model.seek()}}.accessibilityLabel("フレーム位置")
            HStack(spacing:10) {
                Button{model.step(-1)}label:{Image(systemName:"backward.frame")}.keyboardShortcut(.leftArrow,modifiers:[])
                Button{model.togglePlay(backwards:true)}label:{Image(systemName:model.playing && model.reverse ? "pause.fill":"backward.fill")}.help("逆再生（消音）")
                Button{model.togglePlay(backwards:false)}label:{Image(systemName:model.playing ? "pause.fill":"play.fill").frame(width:22)}.keyboardShortcut(.space,modifiers:[])
                Button{model.step(1)}label:{Image(systemName:"forward.frame")}.keyboardShortcut(.rightArrow,modifiers:[])
                Button(action:model.seekByTime){Text(String(format:"%.2f / %.2f秒",model.currentSeconds,model.timeline.duration)).monospacedDigit().font(.caption)}.buttonStyle(.plain).help("秒数を指定して移動")
                Text("\(model.frameIndex+1)/\(model.recording?.packets.count ?? 0)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength:4)
                Button{model.muted.toggle()}label:{Image(systemName:model.muted ? "speaker.slash.fill":"speaker.wave.2.fill")}.buttonStyle(.borderless)
                Slider(value:$model.volume,in:0...1).frame(width:65).accessibilityLabel("音量")
                Picker("速度",selection:$model.playbackRate){ForEach([0.5,1,1.5,2,4],id:\.self){Text(String(format:"%g×",$0)).tag($0)}}.labelsHidden().frame(width:80)
            }
            HStack{Text(model.audioStatus).lineLimit(1);Spacer();if model.reverse || model.playbackRate>2{Text("逆再生・4倍速は消音")};if abs(model.audioDrift)>0.15{Text(String(format:"音声長差 %.2f秒",model.audioDrift)).foregroundStyle(.orange)}}.font(.caption2).foregroundStyle(.secondary)
        }.disabled(model.recording==nil || model.busy)
    }
    private var metadata:some View {
        HStack(alignment:.top,spacing:28) {
            VStack(alignment:.leading,spacing:8){LabeledContent("カード時刻",value:model.packet?.cardTime ?? "—");LabeledContent("速度",value:model.currentSpeedKMH.map{String(format:"%.2f km/h",$0)} ?? "—");LabeledContent("WGS84位置",value:model.coordinate.map{String(format:"%.6f, %.6f",$0.latitude,$0.longitude)} ?? "—");LabeledContent("CH / 種別raw",value:model.packet.map{String($0.channel)} ?? "—");LabeledContent("連続録画",value:model.recording.map{"\($0.blockCount) 保存ブロック / \($0.frameCount) フレーム"} ?? "—")}
            VStack(alignment:.leading,spacing:8){LabeledContent("フレームLBA",value:model.packet.map{String($0.headerSector)} ?? "—");LabeledContent("映像 / 音声",value:model.packet.map{"\($0.videoBytes) / \($0.auxiliaryBytes) bytes"} ?? "—");LabeledContent("加速度raw",value:model.packet?.telemetry.accelerationRaw.map{String($0)}.joined(separator:" / ") ?? "—");LabeledContent("衛星数 / fix raw",value:model.packet.map{"\($0.telemetry.satelliteCount) / \($0.telemetry.fixRaw)"} ?? "—")}
        }.font(.caption).padding(14).frame(maxWidth:.infinity,alignment:.leading)
    }
    private var exportRange:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack{Toggle("範囲指定",isOn:$model.useRange);Button("INを現在位置に"){model.inFrame=model.frameIndex;model.useRange=true};Button("OUTを現在位置に"){model.outFrame=model.frameIndex;model.useRange=true};Button("全範囲"){model.useRange=false};Spacer()}
            Text(model.useRange ? "フレーム \(min(model.inFrame,model.outFrame)+1) – \(max(model.inFrame,model.outFrame)+1)（両端を含む）":"選択中の録画全体を書き出します").font(.caption).monospacedDigit()
            HStack{Toggle("動画に字幕を重ねる",isOn:$model.exportSubtitles);Button("字幕・静止画・GPS出力の設定"){model.showSettings=true}}.font(.caption)
            HStack{Button("音声付きMP4"){model.exportMovie()};Button("Motion JPEG AVI"){model.exportMovie(avi:true)};Button("WAV音声",action:model.exportAudio);Button("連続PNG",action:model.exportSequence);Spacer()}
            Text("表示変換・NIGHT・回転は動画と静止画にも反映。バックアップは元データを保持します。").font(.caption2).foregroundStyle(.secondary)
        }.padding(12).disabled(model.recording==nil || model.busy)
    }
    private var exportMenu:some View {
        Menu {
            Button("表示中の静止画（PNG）"){model.exportStill()};Button("表示中の静止画（JPEG）"){model.exportStill(jpeg:true)}
            Button("音声付きMP4動画"){model.exportMovie()};Button("Motion JPEG AVI動画"){model.exportMovie(avi:true)};Button("WAV音声",action:model.exportAudio);Button("連続PNG",action:model.exportSequence)
            Divider();Button("GPS / センサーCSV"){model.exportLog("csv")};Button("KML（Google Earth対応）"){model.exportLog("kml")};Button("GPX"){model.exportLog("gpx")}
            Divider();Button("選択録画の再生可能バックアップ",action:model.backup);Button("表示中の静止画を印刷"){model.printFrame()};Button("間隔指定のページ印刷"){model.printContactSheet()}
        }label:{Label("書き出し",systemImage:"square.and.arrow.up")}
    }
}
