import Foundation
import AppKit
import AVFoundation
import PCBrowserCore

enum InspectionCLI {
    static func value(_ name:String,in args:[String])->String? {
        guard let i=args.firstIndex(of:name),i+1<args.count else{return nil};return args[i+1]
    }
    static func snapshot(_ url:URL)throws->[String:[String:String]] {
        let paths=FileManager.default.fileExists(atPath:url.appendingPathComponent("manifest.json").path) ? [url.appendingPathComponent("manifest.json"),url.appendingPathComponent("payload.bin")]:[url]
        var result:[String:[String:String]]=[:]
        for p in paths {let a=try FileManager.default.attributesOfItem(atPath:p.path);result[p.lastPathComponent]=["size":String(describing:a[.size] ?? ""),"mtime":String(describing:a[.modificationDate] ?? "")]};return result
    }
    static func run(_ args:[String]) async ->Int32 {
        do {
            guard let path=value("--inspect",in:args) else{return 64}
            let url=URL(fileURLWithPath:path),before=try snapshot(url),began=ProcessInfo.processInfo.systemUptime
            let source=try SourceOpener.open(url,verifyArchiveHash:!args.contains("--catalog-only"))
            let opened=ProcessInfo.processInfo.systemUptime,limit=value("--scan-limit",in:args).flatMap(UInt64.init)
            var firstRowSeconds:Double?
            var result:ImageIndex
            if args.contains("--recovery-scan") {result=try ImageScanner.scan(source,limitBytes:limit)}
            else {result=try CatalogScanner.scan(source,limitBytes:limit){partial,_ in
                if firstRowSeconds==nil,!partial.recordings.isEmpty{firstRowSeconds=ProcessInfo.processInfo.systemUptime-opened}
            }}
            let catalogued=ProcessInfo.processInfo.systemUptime
            let estimatedFrames=result.frameCount,summaryBlocks=result.blockCount
            let mediaRequested = !args.contains("--catalog-only") && (args.contains("--decode-check") || args.contains("--features-check") || value("--export-prefix",in:args) != nil || value("--movie",in:args) != nil || value("--avi",in:args) != nil || value("--print-pdf",in:args) != nil || value("--sequence-dir",in:args) != nil)
            let maximum=value("--max-decode",in:args).flatMap(Int.init) ?? 180
            guard maximum>=0 else{throw BrowserError.invalid("--max-decode は0以上です（0=全フレーム）")}
            if mediaRequested || args.contains("--load-all") {
                var budget=0
                for i in result.recordings.indices {
                    if !args.contains("--load-all"),i>0,(!args.contains("--decode-check") || maximum>0 && budget>=maximum) {break}
                    result.recordings[i]=try CatalogScanner.loadRecording(result.recordings[i],source:source)
                    budget += result.recordings[i].packets.count
                }
            }
            let detailed=ProcessInfo.processInfo.systemUptime
            var report:[String:Any]=["source_bytes":source.byteCount,"control_lba":result.control.sector,"first_record_lba":result.control.firstRecordSector,
                "recordings":result.recordings.count,"storage_blocks":summaryBlocks,"indexed_frames_estimate":estimatedFrames,"validated_frames":result.validatedFrameCount,
                "metadata_catalog":result.isMetadataCatalog,"catalog_seconds":catalogued-opened,"source_open_seconds":opened-began,"detail_load_seconds":detailed-catalogued,
                "catalog_read_calls":result.catalogReadCalls,"backlink_blocks":result.backlinkBlocks,"recovery_recommended":result.recoveryRecommended,
                "loaded_recordings":result.recordings.filter(\.isLoaded).count,"partial_scan":result.isPartialScan,"rejected_candidates":result.rejectedCandidates,
                "mode":"O_RDONLY","scanned_bytes":result.scannedBytes,"timing_note":"Card wall clock + nominal frame slots; no invented UTC; duplicate slot boundaries made monotonic."]
            report["first_catalog_row_seconds"] = firstRowSeconds ?? (catalogued-opened)
            if args.contains("--catalog-details") {
                report["catalog_details"]=result.recordings.map { r in
                    ["session_id":r.id,"frames":r.frameCount,"loaded":r.isLoaded,"blocks":r.blocks.map { b in
                        ["record_lba":UInt64(b.recordSector),"first_header_lba":b.first.headerSector,"last_header_lba":b.last.headerSector,"frames":UInt64(b.frameCount),"frame_ordinal":UInt64(b.metadata?.frameOffset ?? 0)]
                    }] as [String:Any]
                }
            }
            if args.contains("--headers-fixture") {report["source_scope"]="Header-only structural fixture; no H.264/PCM payload, not a complete acquired disk image"}
            report["archive_sha256_verified"] = (source as? ArchiveSource)?.isHashVerified ?? false
            var firstImage:CGImage?,decoded=0,width=0,height=0
            if mediaRequested {
                for recording in result.recordings where recording.isLoaded {
                    if maximum>0,decoded>=maximum {break}
                    guard let first=recording.packets.firstIndex(where:{$0.isIntra}) else{continue}
                    let decoder=NativeVideoDecoder(),fps=Int(RecordingTimeline(packets:recording.packets).nominalFPS)
                    for (j,p) in recording.packets.enumerated() where j>=first {
                        if maximum>0,decoded>=maximum {break}
                        let image=try decoder.decode(source.read(at:p.payloadOffset,count:p.videoBytes),ordinal:j,fps:max(1,fps))
                        width=image.width;height=image.height;if firstImage==nil{firstImage=image};decoded+=1
                    }
                }
                report["native_videotoolbox_decoded_frames"]=decoded;report["width"]=width;report["height"]=height
                if let png=value("--png",in:args),let image=firstImage {try MediaExport.still(image,to:URL(fileURLWithPath:png))}
            }
            if mediaRequested,args.contains("--features-check"),let recording=result.recordings.first {
                let timeline=RecordingTimeline(packets:recording.packets)
                report["first_recording_frames"]=recording.packets.count;report["first_recording_blocks"]=recording.blockCount;report["feature_scope"]="Lazily loaded recordings only; not all-card media validation";report["nominal_fps"]=timeline.nominalFPS;report["timeline_seconds"]=timeline.duration;report["card_clock_used"]=timeline.usedCardClock
                report["valid_gps_frames"]=result.recordings.reduce(0){$0+$1.packets.filter{$0.telemetry.coordinate() != nil}.count}
                report["raw_sensor_frames"]=result.validatedFrameCount
                report["card_setting_files"]=(try? CardSettingsReader.read(source).count) ?? 0
                if recording.packets.contains(where:{$0.auxiliaryBytes>0}) {
                    let format=try PCMFormat.recordFormat(source:source,recording:recording),clip=try AudioClip.load(source:source,packets:recording.packets,format:format)
                    report["audio_format"]=["sample_rate":format.sampleRate,"bits":format.bitsPerSample,"channels":format.channels]
                    report["audio_pcm_bytes"]=clip.samples.count;report["audio_seconds"]=clip.duration;report["audio_minus_video_seconds"]=clip.duration-timeline.duration
                    do {let p=try AVAudioPlayer(data:clip.wav());report["native_audio_prepared"]=p.prepareToPlay();report["native_audio_seconds"]=p.duration}
                    catch {report["native_audio_prepared"]=false;report["native_audio_error"]=error.localizedDescription}
                }
            }
            if mediaRequested,let prefix=value("--export-prefix",in:args),let image=firstImage,let recording=result.recordings.first {
                let base=URL(fileURLWithPath:prefix),folder=base.deletingLastPathComponent()
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let projection=try NativeProjection();var modes:[String:[String:Int]]=[:]
                for mode in ProjectionMode.allCases {
                    var s=ProjectionSettings();s.mode=mode;s.night=args.contains("--night")
                    let rendered=try projection.render(image,settings:s,width:960)
                    try MediaExport.still(rendered,to:URL(fileURLWithPath:prefix+"-"+mode.rawValue+".png"))
                    modes[mode.rawValue]=["width":rendered.width,"height":rendered.height]
                };report["metal_projection_modes"]=modes
                try Data(TrackExport.csv(result.recordings).utf8).write(to:URL(fileURLWithPath:prefix+".csv"),options:.withoutOverwriting)
                var style=TrackStyle();style.showPoints=args.contains("--kml-points");style.showRoute = !args.contains("--kml-no-route")
                style.lineRGB=value("--kml-line-rgb",in:args) ?? style.lineRGB;style.pointRGB=value("--kml-point-rgb",in:args) ?? style.pointRGB
                style.alpha=value("--kml-alpha",in:args).flatMap(Int.init) ?? style.alpha;style.width=value("--kml-width",in:args).flatMap(Double.init) ?? style.width;style.density=value("--kml-density",in:args).flatMap(Int.init) ?? style.density
                try Data(TrackExport.kml(result.recordings,style:style).utf8).write(to:URL(fileURLWithPath:prefix+".kml"),options:.withoutOverwriting)
                try Data(TrackExport.gpx(result.recordings).utf8).write(to:URL(fileURLWithPath:prefix+".gpx"),options:.withoutOverwriting)
                if recording.packets.contains(where:{$0.auxiliaryBytes>0}) {
                    let format=try PCMFormat.recordFormat(source:source,recording:recording),clip=try AudioClip.load(source:source,packets:recording.packets,format:format)
                    try clip.wav().write(to:URL(fileURLWithPath:prefix+".wav"),options:.withoutOverwriting)
                }
                if args.contains("--backup-check") {
                    let backup=URL(fileURLWithPath:prefix+".pcbbackup",isDirectory:true)
                    try ArchiveWriter.write(source:source,index:result,recordings:[recording],name:"Private CLI validation",to:backup)
                    let reopened=try ArchiveSource(url:backup),rescan=try CatalogScanner.scan(reopened)
                    guard rescan.frameCount==recording.packets.count else{throw BrowserError.io("バックアップ再読込のフレーム数が一致しません")}
                    report["backup_roundtrip_frames"]=rescan.frameCount;report["backup_roundtrip_sessions"]=rescan.recordings.count;report["backup_roundtrip_blocks"]=rescan.blockCount;report["backup_hash_verified"]=true
                }
            }
            var externalGPS: GPSLogSynchronization?
            if let file=value("--gps-log",in:args) {
                guard let zoneName=value("--device-time-zone",in:args),let zone=TimeZone(identifier:zoneName) else{throw BrowserError.invalid("外部GPSには --device-time-zone の明示指定が必要です")}
                let url=URL(fileURLWithPath:file),size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                guard size<=32*1024*1024 else{throw BrowserError.invalid("GPSログが32 MiBを超えています")}
                let data=try Data(contentsOf:url);guard data.count<=32*1024*1024 else{throw BrowserError.invalid("GPSログが32 MiBを超えています")}
                let track=ExternalGPSTrack(points:NMEAParser.parse(INIParser.decode(data)).points)
                let offset=value("--gps-offset",in:args).flatMap(Double.init) ?? 0
                guard offset.isFinite,!track.points.isEmpty else{throw BrowserError.invalid("有効なUTC付きGPSログまたは補正秒がありません")}
                externalGPS = .init(track:track,deviceTimeZone:zone,logOffsetSeconds:offset)
                let clock=result.recordings.first?.packets.first?.telemetry.clock,fix=externalGPS?.sample(clock)
                report["external_gps"]=["timestamped_points":track.points.count,"explicit_device_zone":zoneName,"log_offset_seconds":offset,"first_frame_has_fix":fix != nil] as [String:Any]
                if let fix{report["external_gps_first_coordinate"]=[fix.coordinate.latitude,fix.coordinate.longitude]}
            }
            if mediaRequested,let movie=value("--movie",in:args),let recording=result.recordings.first {
                let count=value("--frames",in:args).flatMap(Int.init) ?? 90,start=value("--movie-start",in:args).flatMap(Int.init) ?? 0
                guard count>0,start>=0,start<recording.packets.count else{throw BrowserError.invalid("動画のテスト範囲が不正です")}
                let end=min(recording.packets.count,start+min(count,recording.packets.count))
                var settings=ProjectionSettings();settings.mode=value("--projection",in:args).flatMap(ProjectionMode.init(rawValue:)) ?? .perspective;settings.night=args.contains("--night")
                var options=MovieExportOptions(frames:start..<end);options.projection=settings;options.subtitles=args.contains("--subtitles");options.audio = !args.contains("--no-audio");options.width=1280;options.subtitleFields=args.contains("--subtitle-all") ? .all:.defaults;options.externalGPS=externalGPS
                let output=URL(fileURLWithPath:movie)
                try await MediaExport.movie(source:source,recording:recording,options:options,to:output)
                let asset=AVURLAsset(url:output),duration=try await asset.load(.duration),video=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
                report["movie_export"]=["start_frame":start,"frames":end-start,"duration":duration.seconds,"video_tracks":video.count,"audio_tracks":audio.count,"subtitles":options.subtitles,"projection":settings.mode.rawValue]
                if let v=video.first {let size=try await v.load(.naturalSize);report["movie_size"]=["width":size.width,"height":size.height]}
            }
            if mediaRequested,let recording=result.recordings.first {
                let start=value("--movie-start",in:args).flatMap(Int.init) ?? 0
                let count=value("--frames",in:args).flatMap(Int.init) ?? recording.packets.count
                guard start>=0,start<recording.packets.count,count>0 else{throw BrowserError.invalid("出力のテスト範囲が不正です")}
                let end=start+min(count,recording.packets.count-start),range=start..<end
                var settings=ProjectionSettings();settings.mode=value("--projection",in:args).flatMap(ProjectionMode.init(rawValue:)) ?? .perspective;settings.night=args.contains("--night")
                if let avi=value("--avi",in:args) {
                    var options=MovieExportOptions(frames:range);options.projection=settings;options.subtitles=args.contains("--subtitles");options.subtitleFields=args.contains("--subtitle-all") ? .all:.defaults
                    options.externalGPS=externalGPS;options.audio = !args.contains("--no-audio");options.width=1280
                    let summary=try await MediaExport.avi(source:source,recording:recording,options:options,to:URL(fileURLWithPath:avi),segmentLimit:value("--avi-segment-bytes",in:args).flatMap(UInt64.init) ?? 1_000_000_000)
                    report["avi_export"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(summary))
                }
                if value("--print-pdf",in:args) != nil || value("--sequence-dir",in:args) != nil {
                    let timeline=RecordingTimeline(packets:recording.packets)
                    let indices=try FrameSampling.indices(starts:timeline.starts,range:range,everyFrames:value("--frame-step",in:args).flatMap(Int.init) ?? 1,everySeconds:value("--sample-seconds",in:args).flatMap(Double.init))
                    if let path=value("--print-pdf",in:args) {
                        let summary=try await FrameExport.printPDF(source:source,recording:recording,indices:indices,framesPerPage:value("--print-layout",in:args).flatMap(Int.init) ?? 4,settings:settings,to:URL(fileURLWithPath:path))
                        report["print_pdf"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(summary))
                    }
                    if let path=value("--sequence-dir",in:args) {
                        let summary=try await FrameExport.sequence(source:source,recording:recording,indices:indices,settings:settings,to:URL(fileURLWithPath:path,isDirectory:true))
                        report["still_sequence"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(summary))
                    }
                }
            }
            report["total_seconds"] = ProcessInfo.processInfo.systemUptime-began
            report["input_size_and_mtime_unchanged"] = before == (try snapshot(url))
            let bytes=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            if let file=value("--report",in:args) {try bytes.write(to:URL(fileURLWithPath:file),options:.atomic)}
            print(String(decoding:bytes,as:UTF8.self));return 0
        }catch{let e=error as NSError;fputs("\(e.localizedDescription) [\(e.domain) \(e.code)] \(e.userInfo)\n",stderr);return 1}
    }
}
