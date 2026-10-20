import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum ACPSubmitIntent: Equatable, Sendable { case auto, steer, schedule(Date) }
