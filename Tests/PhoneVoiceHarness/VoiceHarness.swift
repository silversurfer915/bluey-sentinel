import Foundation
@main struct Audit { static func main() {
 let live=LiveVoice()
 live.receiveReply("Late reply")
 guard live.state == .asleep else { print("FAIL: stale reply woke sleeping phone: \(live.state)"); exit(1) }
 live.receiveCaption("Late caption",done:true)
 guard live.state == .asleep else { print("FAIL: stale caption woke sleeping phone");exit(1) }
 print("PASS: sleeping phone ignores delayed replies and captions")
} }
