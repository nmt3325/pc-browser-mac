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
            let mediaRequested = !args.contains("--catalog-only") && (args.contains("--decode-check") || args.contains("--features-check") || value("--export-prefix",in:args) != nil || value("--movie",in:args) != nil)
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
                try Data(TrackExport.kml(result.recordings).utf8).write(to:URL(fileURLWithPath:prefix+".kml"),options:.withoutOverwriting)
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
            if mediaRequested,let movie=value("--movie",in:args),let recording=result.recordings.first {
                let count=value("--frames",in:args).flatMap(Int.init) ?? 90,start=value("--movie-start",in:args).flatMap(Int.init) ?? 0
                guard count>0,start>=0,start<recording.packets.count else{throw BrowserError.invalid("動画のテスト範囲が不正です")}
                let end=min(recording.packets.count,start+min(count,recording.packets.count))
                var settings=ProjectionSettings();settings.mode=value("--projection",in:args).flatMap(ProjectionMode.init(rawValue:)) ?? .perspective;settings.night=args.contains("--night")
                var options=MovieExportOptions(frames:start..<end);options.projection=settings;options.subtitles=args.contains("--subtitles");options.audio = !args.contains("--no-audio");options.width=1280
                let output=URL(fileURLWithPath:movie)
                try await MediaExport.movie(source:source,recording:recording,options:options,to:output)
                let asset=AVURLAsset(url:output),duration=try await asset.load(.duration),video=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
                report["movie_export"]=["start_frame":start,"frames":end-start,"duration":duration.seconds,"video_tracks":video.count,"audio_tracks":audio.count,"subtitles":options.subtitles,"projection":settings.mode.rawValue]
                if let v=video.first {let size=try await v.load(.naturalSize);report["movie_size"]=["width":size.width,"height":size.height]}
            }
            report["total_seconds"] = ProcessInfo.processInfo.systemUptime-began
            report["input_size_and_mtime_unchanged"] = before == (try snapshot(url))
            let bytes=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            if let file=value("--report",in:args) {try bytes.write(to:URL(fileURLWithPath:file),options:.atomic)}
            print(String(decoding:bytes,as:UTF8.self));return 0
        }catch{let e=error as NSError;fputs("\(e.localizedDescription) [\(e.domain) \(e.code)] \(e.userInfo)\n",stderr);return 1}
    }
}
