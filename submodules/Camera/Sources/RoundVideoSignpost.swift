import Foundation
import os

// Physical-device profiling signposts. Filter Instruments by the
// `org.telegram.roundvideo` subsystem; call-site names must remain string literals.
public enum RoundVideoSignpost {
    public static let log = OSLog(subsystem: "org.telegram.roundvideo", category: "Recording")
}
